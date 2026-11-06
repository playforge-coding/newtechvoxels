// The game client. Opens a window with SDL3, renders with wgpu, and in
// singleplayer runs a host in the same process over the in-memory
// transport, talking to it exactly as it would to a dedicated server.
// `--bench` runs a scripted scene instead of taking input and writes
// telemetry; `--headless` does that without a window.
package client

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"

import sdl "vendor:sdl3"
import "vendor:wgpu"
import sdl3glue "vendor:wgpu/sdl3glue"

import "../host"
import "../net"
import "../render"
import "../session"
import "../sim"
import "../storage"
import "../telemetry"
import "../world"

Options :: struct {
	save:          string,
	seed:          u64,
	bench:         string,
	bench_seconds: f64,
	bench_out:     string,
	headless:      bool,
	width, height: u32,
	view_radius:   i32,
	name:          string,
}

DEFAULT_OPTIONS :: Options {
	save          = "saves/default",
	seed          = 1,
	bench_seconds = 20,
	bench_out     = "out/bench",
	width         = 1280,
	height        = 720,
	view_radius   = 4,
	name          = "player",
}

// What the player is doing, kept between frames and sampled per tick.
Controls :: struct {
	forward, back, left, right, up, down, jump: bool,
	flying:                                     bool,
	yaw, pitch:                                 f32,
	// Set by a click, consumed by the next tick.
	action:                                     sim.Action,
	hold_break, hold_place:                     bool,
	hold_ticks:                                 int,
	block:                                      world.Block_Id,
	mouse_captured:                             bool,
}

Game :: struct {
	opts:       Options,
	registry:   world.Registry,
	terrain:    world.Terrain,
	store:      storage.File_Storage,
	game_world: world.World,
	hub:        net.Memory_Hub,
	server:     host.Host,
	client:     session.Client,
	renderer:   render.Renderer,
	window:     ^sdl.Window,
	controls:   Controls,
	// Tick pacing: the client and host tick together.
	accum:      f32,
	prev_pos:   [3]f32,
	recorder:   telemetry.Recorder,
	started:    time.Tick,
}

main :: proc() {
	context.logger = log.create_console_logger(.Info)
	defer log.destroy_console_logger(context.logger)

	opts, ok := parse_args(os.args[1:])
	if !ok {
		os.exit(2)
	}
	if opts.bench == "all" {
		for scene in BENCH_SCENES {
			o := opts
			o.bench = scene
			run(o)
		}
		return
	}
	run(opts)
}

@(private = "file")
run :: proc(opts: Options) {
	g := new(Game)
	defer free(g)
	g.opts = opts
	g.started = time.tick_now()
	if !game_init(g) {
		os.exit(1)
	}
	defer game_destroy(g)
	game_loop(g)
}

BENCH_SCENES :: [?]string{"terrain", "edits", "static"}

usage :: proc() {
	fmt.eprintln(
		`newtechvoxels [options]
  --save <dir>          world directory (default saves/default)
  --seed <n>            world seed for a new world (default 1)
  --view <chunks>       view radius in chunks (default 4)
  --name <name>         player name
  --size <w>x<h>        window size (default 1280x720)
  --bench <scene>       run a benchmark scene: terrain, edits, static, all
  --bench-seconds <s>   how long a scene runs (default 20)
  --bench-out <dir>     where the CSVs go (default out/bench)
  --headless            no window; render offscreen (benchmarks)`,
	)
}

parse_args :: proc(args: []string) -> (opts: Options, ok: bool) {
	opts = DEFAULT_OPTIONS
	i := 0
	next :: proc(args: []string, i: ^int) -> (string, bool) {
		if i^ + 1 >= len(args) {
			return "", false
		}
		i^ += 1
		return args[i^], true
	}
	for i < len(args) {
		a := args[i]
		value: string
		got := true
		switch a {
		case "--save":
			value, got = next(args, &i)
			opts.save = value
		case "--seed":
			value, got = next(args, &i)
			opts.seed, got = strconv.parse_u64(value)
		case "--view":
			value, got = next(args, &i)
			v, vok := strconv.parse_int(value)
			opts.view_radius = i32(v)
			got &&= vok
		case "--name":
			value, got = next(args, &i)
			opts.name = value
		case "--size":
			value, got = next(args, &i)
			parts := strings.split(value, "x", context.temp_allocator)
			if len(parts) != 2 {
				got = false
			} else {
				w, wok := strconv.parse_int(parts[0])
				h, hok := strconv.parse_int(parts[1])
				opts.width, opts.height = u32(w), u32(h)
				got = wok && hok
			}
		case "--bench":
			value, got = next(args, &i)
			opts.bench = value
		case "--bench-seconds":
			value, got = next(args, &i)
			opts.bench_seconds, got = strconv.parse_f64(value)
		case "--bench-out":
			value, got = next(args, &i)
			opts.bench_out = value
		case "--headless":
			opts.headless = true
		case "--help", "-h":
			usage()
			return opts, false
		case:
			fmt.eprintfln("unknown option %s", a)
			usage()
			return opts, false
		}
		if !got {
			fmt.eprintfln("bad or missing value for %s", a)
			return opts, false
		}
		i += 1
	}
	if opts.bench != "" {
		known := opts.bench == "all"
		for scene in BENCH_SCENES {
			known ||= scene == opts.bench
		}
		if !known {
			fmt.eprintfln("unknown bench scene %s", opts.bench)
			return opts, false
		}
	}
	return opts, true
}

game_init :: proc(g: ^Game) -> bool {
	world.registry_init(&g.registry)
	world.register_builtin_blocks(&g.registry)
	g.terrain = {
		params = world.DEFAULT_TERRAIN,
	}
	g.terrain.params.seed = g.opts.seed

	store: world.Storage
	if g.opts.bench == "" {
		if err := storage.file_storage_init(&g.store, g.opts.save); err != .None {
			log.errorf("could not open the save directory %s", g.opts.save)
			return false
		}
		store = storage.file_storage(&g.store)
	}
	world.world_init(&g.game_world, &g.registry, world.terrain_generator(&g.terrain), store)

	net.memory_hub_init(&g.hub)
	host_config := host.DEFAULT_CONFIG
	host_config.view_radius = g.opts.view_radius
	host.host_init(&g.server, &g.game_world, net.memory_hub_transport(&g.hub), host_config)
	session.client_init(&g.client, &g.registry, net.memory_connect(&g.hub), g.opts.name)

	g.controls.block = world.Block_Id(world.Builtin.Brick)

	surface: wgpu.Surface
	if !g.opts.headless {
		if !sdl.Init({.VIDEO}) {
			log.errorf("SDL init failed: %s", sdl.GetError())
			return false
		}
		g.window = sdl.CreateWindow(
			"New Tech Voxels",
			i32(g.opts.width),
			i32(g.opts.height),
			{.RESIZABLE, .HIGH_PIXEL_DENSITY},
		)
		if g.window == nil {
			log.errorf("window creation failed: %s", sdl.GetError())
			return false
		}
		w, h: i32
		sdl.GetWindowSizeInPixels(g.window, &w, &h)
		g.opts.width, g.opts.height = u32(w), u32(h)
		instance := wgpu.CreateInstance(nil)
		surface = sdl3glue.GetSurface(instance, g.window)
		if err := render.renderer_init(
			&g.renderer,
			surface,
			g.opts.width,
			g.opts.height,
			instance,
		); err != .None {
			log.errorf("renderer init failed: %v", err)
			return false
		}
	} else {
		if err := render.renderer_init(&g.renderer, nil, g.opts.width, g.opts.height);
		   err != .None {
			log.errorf("renderer init failed: %v", err)
			return false
		}
	}
	render.set_registry(&g.renderer, &g.registry)
	telemetry.recorder_init(&g.recorder)
	return true
}

game_destroy :: proc(g: ^Game) {
	telemetry.recorder_destroy(&g.recorder)
	render.renderer_destroy(&g.renderer)
	if g.window != nil {
		sdl.DestroyWindow(g.window)
		sdl.Quit()
	}
	session.client_destroy(&g.client)
	host.host_destroy(&g.server)
	world.world_destroy(&g.game_world)
	world.registry_destroy(&g.registry)
}

// One tick of both sides, client first so a round trip takes a tick each
// way, as it would over a network.
tick :: proc(g: ^Game, input: sim.Input) {
	if p, ok := session.local_player(&g.client); ok {
		g.prev_pos = p.pos
	}
	session.client_tick(&g.client, input)
	host.host_tick(&g.server)
	if g.client.status == .Joined && g.client.input_tick <= 1 {
		if p, ok := session.local_player(&g.client); ok {
			g.prev_pos = p.pos
		}
	}
}

// Pushes the client's chunk changes to the renderer.
sync_chunks :: proc(g: ^Game) {
	for pos in g.client.removed {
		render.remove_chunk(&g.renderer, pos)
	}
	clear(&g.client.removed)
	for pos in g.client.changed {
		if c := world.world_chunk(&g.client.mirror, pos); c != nil && c.dirty {
			render.upload_chunk(&g.renderer, c)
			c.dirty = false
		}
	}
	clear(&g.client.changed)
}

input_from_controls :: proc(c: ^Controls) -> (input: sim.Input) {
	if c.forward {input.move.z += 1}
	if c.back {input.move.z -= 1}
	if c.right {input.move.x += 1}
	if c.left {input.move.x -= 1}
	if c.up {input.move.y += 1}
	if c.down {input.move.y -= 1}
	input.jump = c.jump
	input.flying = c.flying
	input.yaw = c.yaw
	input.pitch = c.pitch
	input.place_block = c.block
	input.action = c.action
	c.action = .None
	// Holding a button repeats every few ticks.
	if c.hold_break || c.hold_place {
		c.hold_ticks += 1
		if c.hold_ticks % 5 == 0 {
			input.action = c.hold_break ? .Break : .Place
		}
	} else {
		c.hold_ticks = 0
	}
	return
}

MOUSE_SENSITIVITY :: 0.0025

handle_events :: proc(g: ^Game) -> (quit: bool) {
	c := &g.controls
	e: sdl.Event
	for sdl.PollEvent(&e) {
		#partial switch e.type {
		case .QUIT:
			return true
		case .WINDOW_PIXEL_SIZE_CHANGED, .WINDOW_RESIZED:
			w, h: i32
			sdl.GetWindowSizeInPixels(g.window, &w, &h)
			render.renderer_resize(&g.renderer, u32(w), u32(h))
		case .KEY_DOWN, .KEY_UP:
			down := e.key.down
			#partial switch e.key.scancode {
			case .W:
				c.forward = down
			case .S:
				c.back = down
			case .A:
				c.left = down
			case .D:
				c.right = down
			case .SPACE:
				c.jump = down
				c.up = down
			case .LSHIFT:
				c.down = down
			case .F:
				if down && !e.key.repeat {
					c.flying = !c.flying
				}
			case .ESCAPE:
				if down {
					c.mouse_captured = false
					_ = sdl.SetWindowRelativeMouseMode(g.window, false)
				}
			case ._1 ..= ._9:
				if down {
					id := world.Block_Id(int(e.key.scancode) - int(sdl.Scancode._1) + 1)
					if int(id) < len(g.registry.defs) {
						c.block = id
					}
				}
			}
		case .MOUSE_MOTION:
			if c.mouse_captured {
				// Moving right turns right, which is a smaller yaw (see
				// sim.look_dir).
				c.yaw -= e.motion.xrel * MOUSE_SENSITIVITY
				c.pitch -= e.motion.yrel * MOUSE_SENSITIVITY
				c.pitch = clamp(c.pitch, -math.PI / 2 + 0.01, math.PI / 2 - 0.01)
			}
		case .MOUSE_BUTTON_DOWN:
			if !c.mouse_captured {
				c.mouse_captured = true
				_ = sdl.SetWindowRelativeMouseMode(g.window, true)
				break
			}
			switch e.button.button {
			case 1:
				c.action = .Break
				c.hold_break = true
			case 3:
				c.action = .Place
				c.hold_place = true
			}
		case .MOUSE_BUTTON_UP:
			switch e.button.button {
			case 1:
				c.hold_break = false
			case 3:
				c.hold_place = false
			}
		}
	}
	return false
}

game_loop :: proc(g: ^Game) {
	tick_dt := sim.tick_seconds(&g.server.game)
	last := time.tick_now()
	bench := g.opts.bench != ""
	frames := 0
	title_timer: f32
	for {
		now := time.tick_now()
		dt := f32(time.duration_seconds(time.tick_diff(last, now)))
		last = now
		elapsed := time.duration_seconds(time.tick_diff(g.started, now))
		if dt > 0.25 {
			dt = 0.25
		}
		if g.window != nil && handle_events(g) {
			break
		}
		if bench {
			if elapsed > g.opts.bench_seconds {
				break
			}
			bench_controls(g, elapsed)
		}

		// Ticks.
		tick_start := time.tick_now()
		ticks := 0
		g.accum += dt
		for g.accum >= tick_dt {
			g.accum -= tick_dt
			tick(g, input_from_controls(&g.controls))
			ticks += 1
		}
		tick_ms := time.duration_milliseconds(time.tick_since(tick_start))
		sync_chunks(g)

		// Camera: the predicted player, interpolated between ticks.
		cam := render.DEFAULT_CAMERA
		if p, ok := session.local_player(&g.client); ok {
			alpha := g.accum / tick_dt
			pos := g.prev_pos + (p.pos - g.prev_pos) * alpha
			cam.position = pos + {0, g.server.game.config.eye_height, 0}
		}
		cam.yaw = g.controls.yaw
		cam.pitch = g.controls.pitch
		g.renderer.chunks.stats = {}
		render.render_frame(&g.renderer, cam)
		frames += 1

		frame_ms := time.duration_milliseconds(time.tick_since(now))
		telemetry.record(
			&g.recorder,
			{
				time = elapsed,
				frame_ms = frame_ms,
				tick_ms = tick_ms,
				ticks = ticks,
				chunks_meshed = g.renderer.chunks.stats.meshed,
				chunks_drawn = g.renderer.chunks.stats.drawn,
				faces_drawn = g.renderer.chunks.stats.faces_drawn,
				chunks_uploaded = g.renderer.chunks.stats.uploaded,
				chunks_loaded = len(g.game_world.chunks),
				chunks_received = g.client.stats.chunks_received,
				bytes_received = g.client.stats.bytes_received,
				bytes_sent = g.client.stats.bytes_sent,
			},
		)

		title_timer += dt
		if g.window != nil && title_timer > 0.5 {
			title_timer = 0
			s := telemetry.summarize(&g.recorder)
			title := fmt.ctprintf(
				"New Tech Voxels  %.1f ms  (%d chunks, %d faces)  %s",
				s.average_ms,
				g.renderer.chunks.stats.drawn,
				g.renderer.chunks.stats.faces_drawn,
				g.renderer.adapter_name,
			)
			sdl.SetWindowTitle(g.window, title)
		}
		free_all(context.temp_allocator)
	}
	render.wait_idle(&g.renderer)
	finish_telemetry(g)
}

finish_telemetry :: proc(g: ^Game) {
	s := telemetry.summarize(&g.recorder)
	summary := telemetry.format_summary(s, context.temp_allocator)
	if g.opts.bench != "" {
		os.make_directory_all(g.opts.bench_out)
		path, _ := filepath.join(
			{g.opts.bench_out, fmt.tprintf("%s.csv", g.opts.bench)},
			context.temp_allocator,
		)
		if telemetry.write_csv(&g.recorder, path) {
			log.infof("bench %s on %s: %s", g.opts.bench, g.renderer.adapter_name, summary)
			log.infof("wrote %s", path)
		} else {
			log.errorf("could not write %s", path)
		}
	} else {
		log.infof("session: %s", summary)
	}
}

// Scripted controls for the benchmark scenes.
bench_controls :: proc(g: ^Game, elapsed: f64) {
	c := &g.controls
	c.flying = true
	switch g.opts.bench {
	case "terrain":
		// Fly forward over new terrain, looking slightly down.
		c.forward = true
		c.pitch = -0.35
		c.yaw = 0.3
	case "edits":
		// Stand still and break the ground, then place, as fast as the
		// tick allows.
		c.pitch = -1.2
		c.yaw = f32(elapsed) * 0.7
		c.hold_break = int(elapsed * 2) % 2 == 0
		c.hold_place = !c.hold_break
		c.hold_ticks = 4
	case "static":
		// Look around without moving: the renderer alone.
		c.yaw = f32(elapsed) * 0.5
		c.pitch = -0.2
	}
}
