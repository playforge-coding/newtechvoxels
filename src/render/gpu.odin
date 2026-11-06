// The wgpu device and, when there is a window, the surface. Everything the
// renderer draws goes through the Renderer here; chunks.odin adds the
// chunk pipelines on top. Without a surface the renderer is headless, for
// tests and benchmarks: it renders into its own texture.
package render

import "base:runtime"
import "core:fmt"
import "core:log"

import "vendor:wgpu"

Init_Error :: enum {
	None,
	No_Instance,
	No_Adapter,
	No_Device,
	Missing_Feature,
}

Renderer :: struct {
	instance:       wgpu.Instance,
	adapter:        wgpu.Adapter,
	device:         wgpu.Device,
	queue:          wgpu.Queue,
	// nil when headless.
	surface:        wgpu.Surface,
	config:         wgpu.SurfaceConfiguration,
	format:         wgpu.TextureFormat,
	width:          u32,
	height:         u32,
	depth:          wgpu.Texture,
	depth_view:     wgpu.TextureView,
	// Headless targets.
	offscreen:      wgpu.Texture,
	offscreen_view: wgpu.TextureView,
	chunks:         Chunk_Renderer,
	ctx:            runtime.Context,
	adapter_name:   string,
}

// Error output from the device goes to the log.
@(private = "file")
on_error :: proc "c" (
	device: ^wgpu.Device,
	type: wgpu.ErrorType,
	message: string,
	userdata1, userdata2: rawptr,
) {
	r := (^Renderer)(userdata1)
	context = r.ctx
	log.errorf("wgpu %v: %s", type, message)
}

// Creates the device. `surface` may be nil for headless use; then `width`
// and `height` size the offscreen target.
renderer_init :: proc(
	r: ^Renderer,
	surface: wgpu.Surface,
	width, height: u32,
	instance: wgpu.Instance = nil,
) -> Init_Error {
	r.ctx = context
	r.instance = instance if instance != nil else wgpu.CreateInstance(nil)
	if r.instance == nil {
		return .No_Instance
	}
	r.surface = surface
	r.width, r.height = width, height

	Request :: struct {
		adapter: wgpu.Adapter,
		device:  wgpu.Device,
		ctx:     runtime.Context,
		message: string,
	}
	req := Request {
		ctx = context,
	}
	wgpu.InstanceRequestAdapter(
		r.instance,
		&{compatibleSurface = surface, powerPreference = .HighPerformance},
		{callback = on_adapter, userdata1 = &req},
	)
	on_adapter :: proc "c" (
		status: wgpu.RequestAdapterStatus,
		adapter: wgpu.Adapter,
		message: string,
		userdata1, userdata2: rawptr,
	) {
		req := (^Request)(userdata1)
		context = req.ctx
		if status == .Success {
			req.adapter = adapter
		} else {
			req.message = fmt.aprint(message)
		}
	}
	wgpu.InstanceProcessEvents(r.instance)
	if req.adapter == nil {
		log.errorf("no adapter: %s", req.message)
		return .No_Adapter
	}
	r.adapter = req.adapter
	info, _ := wgpu.AdapterGetInfo(r.adapter)
	r.adapter_name = fmt.aprintf("%s (%v, %v)", info.device, info.backendType, info.adapterType)
	log.infof("adapter: %s", r.adapter_name)

	// Indirect draws with a first instance let one draw per chunk read its
	// faces straight from the chunk's range.
	if !wgpu.AdapterHasFeature(r.adapter, .IndirectFirstInstance) {
		log.error("the adapter lacks IndirectFirstInstance")
		return .Missing_Feature
	}
	features := []wgpu.FeatureName{.IndirectFirstInstance}
	limits, _ := wgpu.AdapterGetLimits(r.adapter)
	wgpu.AdapterRequestDevice(
		r.adapter,
		&{
			requiredFeatureCount = len(features),
			requiredFeatures = raw_data(features),
			requiredLimits = &limits,
			uncapturedErrorCallbackInfo = {callback = on_error, userdata1 = r},
		},
		{callback = on_device, userdata1 = &req},
	)
	on_device :: proc "c" (
		status: wgpu.RequestDeviceStatus,
		device: wgpu.Device,
		message: string,
		userdata1, userdata2: rawptr,
	) {
		req := (^Request)(userdata1)
		context = req.ctx
		if status == .Success {
			req.device = device
		} else {
			req.message = fmt.aprint(message)
		}
	}
	wgpu.InstanceProcessEvents(r.instance)
	if req.device == nil {
		log.errorf("no device: %s", req.message)
		return .No_Device
	}
	r.device = req.device
	r.queue = wgpu.DeviceGetQueue(r.device)

	if surface != nil {
		caps, _ := wgpu.SurfaceGetCapabilities(surface, r.adapter)
		defer wgpu.SurfaceCapabilitiesFreeMembers(caps)
		r.format = .BGRA8Unorm
		if caps.formatCount > 0 {
			r.format = caps.formats[0]
			for i in 0 ..< caps.formatCount {
				if caps.formats[i] == .BGRA8Unorm || caps.formats[i] == .RGBA8Unorm {
					r.format = caps.formats[i]
					break
				}
			}
		}
		r.config = wgpu.SurfaceConfiguration {
			device      = r.device,
			usage       = {.RenderAttachment},
			format      = r.format,
			width       = width,
			height      = height,
			presentMode = .Fifo,
			alphaMode   = .Opaque,
		}
		wgpu.SurfaceConfigure(surface, &r.config)
	} else {
		r.format = .RGBA8Unorm
	}
	create_targets(r)
	chunk_renderer_init(r)
	return .None
}

renderer_destroy :: proc(r: ^Renderer) {
	chunk_renderer_destroy(r)
	release_targets(r)
	if r.queue != nil {wgpu.QueueRelease(r.queue)}
	if r.device != nil {wgpu.DeviceRelease(r.device)}
	if r.adapter != nil {wgpu.AdapterRelease(r.adapter)}
	if r.surface != nil {wgpu.SurfaceRelease(r.surface)}
	if r.instance != nil {wgpu.InstanceRelease(r.instance)}
	delete(r.adapter_name)
}

// Called when the window changed size.
renderer_resize :: proc(r: ^Renderer, width, height: u32) {
	if width == 0 || height == 0 || (width == r.width && height == r.height) {
		return
	}
	r.width, r.height = width, height
	if r.surface != nil {
		r.config.width, r.config.height = width, height
		wgpu.SurfaceConfigure(r.surface, &r.config)
	}
	release_targets(r)
	create_targets(r)
}

@(private = "file")
create_targets :: proc(r: ^Renderer) {
	r.depth = wgpu.DeviceCreateTexture(
		r.device,
		&{
			label = "depth",
			usage = {.RenderAttachment},
			dimension = ._2D,
			size = {r.width, r.height, 1},
			format = .Depth24Plus,
			mipLevelCount = 1,
			sampleCount = 1,
		},
	)
	r.depth_view = wgpu.TextureCreateView(r.depth, nil)
	if r.surface == nil {
		r.offscreen = wgpu.DeviceCreateTexture(
			r.device,
			&{
				label = "offscreen",
				usage = {.RenderAttachment, .CopySrc},
				dimension = ._2D,
				size = {r.width, r.height, 1},
				format = r.format,
				mipLevelCount = 1,
				sampleCount = 1,
			},
		)
		r.offscreen_view = wgpu.TextureCreateView(r.offscreen, nil)
	}
}

@(private = "file")
release_targets :: proc(r: ^Renderer) {
	if r.depth_view != nil {wgpu.TextureViewRelease(r.depth_view)}
	if r.depth != nil {wgpu.TextureRelease(r.depth)}
	if r.offscreen_view != nil {wgpu.TextureViewRelease(r.offscreen_view)}
	if r.offscreen != nil {wgpu.TextureRelease(r.offscreen)}
	r.depth, r.depth_view, r.offscreen, r.offscreen_view = nil, nil, nil, nil
}

// The color target for this frame: the surface's texture, or the
// offscreen one. `ok` is false when the surface had nothing to give (the
// window is minimized or the surface was lost and reconfigured).
Frame :: struct {
	texture: wgpu.Texture,
	view:    wgpu.TextureView,
	surface: bool,
}

begin_frame :: proc(r: ^Renderer) -> (f: Frame, ok: bool) {
	if r.surface == nil {
		return Frame{texture = r.offscreen, view = r.offscreen_view}, true
	}
	st := wgpu.SurfaceGetCurrentTexture(r.surface)
	switch st.status {
	case .SuccessOptimal, .SuccessSuboptimal:
	case .Timeout, .Outdated, .Lost:
		if st.texture != nil {
			wgpu.TextureRelease(st.texture)
		}
		wgpu.SurfaceConfigure(r.surface, &r.config)
		return {}, false
	case .Occluded:
		if st.texture != nil {
			wgpu.TextureRelease(st.texture)
		}
		return {}, false
	case .Error:
		log.error("surface error")
		return {}, false
	}
	return Frame {
			texture = st.texture,
			view = wgpu.TextureCreateView(st.texture, nil),
			surface = true,
		},
		true
}

end_frame :: proc(r: ^Renderer, f: Frame) {
	if f.surface {
		wgpu.SurfacePresent(r.surface)
		wgpu.TextureViewRelease(f.view)
		wgpu.TextureRelease(f.texture)
	}
}

// One whole frame: meshes dirty chunks, clears, draws the world. Returns
// false when there was no target this frame.
render_frame :: proc(r: ^Renderer, camera: Camera) -> bool {
	frame, ok := begin_frame(r)
	if !ok {
		return false
	}
	defer end_frame(r, frame)
	encoder := wgpu.DeviceCreateCommandEncoder(r.device, nil)
	defer wgpu.CommandEncoderRelease(encoder)

	mesh_dirty(r, encoder)

	pass := wgpu.CommandEncoderBeginRenderPass(
		encoder,
		&{
			colorAttachmentCount = 1,
			colorAttachments = &wgpu.RenderPassColorAttachment {
				view = frame.view,
				loadOp = .Clear,
				storeOp = .Store,
				depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
				clearValue = {0.62, 0.76, 0.92, 1},
			},
			depthStencilAttachment = &{
				view = r.depth_view,
				depthLoadOp = .Clear,
				depthStoreOp = .Store,
				depthClearValue = 1,
			},
		},
	)
	cam := camera
	cam.aspect = f32(r.width) / f32(max(r.height, 1))
	draw_chunks(r, pass, cam)
	wgpu.RenderPassEncoderEnd(pass)
	wgpu.RenderPassEncoderRelease(pass)

	commands := wgpu.CommandEncoderFinish(encoder, nil)
	defer wgpu.CommandBufferRelease(commands)
	wgpu.QueueSubmit(r.queue, {commands})
	return true
}

// Waits for everything submitted so far to finish.
wait_idle :: proc(r: ^Renderer) {
	wgpu.DevicePoll(r.device, true)
}

// Copies part of a GPU buffer back to the CPU, waiting for it. This is for
// tests and debugging only; the renderer itself never reads back.
read_buffer :: proc(
	r: ^Renderer,
	buffer: wgpu.Buffer,
	offset, size: u64,
	allocator := context.allocator,
) -> []u8 {
	staging := wgpu.DeviceCreateBuffer(
		r.device,
		&{label = "readback", size = size, usage = {.MapRead, .CopyDst}},
	)
	defer wgpu.BufferRelease(staging)
	encoder := wgpu.DeviceCreateCommandEncoder(r.device, nil)
	wgpu.CommandEncoderCopyBufferToBuffer(encoder, buffer, offset, staging, 0, size)
	commands := wgpu.CommandEncoderFinish(encoder, nil)
	wgpu.CommandEncoderRelease(encoder)
	wgpu.QueueSubmit(r.queue, {commands})
	wgpu.CommandBufferRelease(commands)

	Map_State :: struct {
		done: bool,
		ok:   bool,
	}
	state: Map_State
	wgpu.BufferMapAsync(staging, {.Read}, 0, uint(size), {callback = on_map, userdata1 = &state})
	on_map :: proc "c" (
		status: wgpu.MapAsyncStatus,
		message: string,
		userdata1, userdata2: rawptr,
	) {
		st := (^Map_State)(userdata1)
		st.done = true
		st.ok = status == .Success
	}
	for !state.done {
		wgpu.DevicePoll(r.device, true)
	}
	out := make([]u8, int(size), allocator)
	if state.ok {
		mapped := wgpu.BufferGetConstMappedRange(staging, 0, uint(size))
		copy(out, mapped)
		wgpu.BufferUnmap(staging)
	}
	return out
}

// Reads the headless target (or a given texture) back as RGBA8 rows, for
// screenshots. Tests and the --screenshot option use it; the renderer
// itself never reads back.
read_target :: proc(
	r: ^Renderer,
	texture: wgpu.Texture,
	allocator := context.allocator,
) -> (
	pixels: []u8,
	width, height: int,
) {
	// Rows are padded to 256 bytes for the copy.
	row := (int(r.width) * 4 + 255) / 256 * 256
	size := u64(row * int(r.height))
	staging := wgpu.DeviceCreateBuffer(
		r.device,
		&{label = "screenshot", size = size, usage = {.MapRead, .CopyDst}},
	)
	defer wgpu.BufferRelease(staging)
	encoder := wgpu.DeviceCreateCommandEncoder(r.device, nil)
	wgpu.CommandEncoderCopyTextureToBuffer(
		encoder,
		&{texture = texture, aspect = .All},
		&{buffer = staging, layout = {bytesPerRow = u32(row), rowsPerImage = r.height}},
		&{r.width, r.height, 1},
	)
	commands := wgpu.CommandEncoderFinish(encoder, nil)
	wgpu.CommandEncoderRelease(encoder)
	wgpu.QueueSubmit(r.queue, {commands})
	wgpu.CommandBufferRelease(commands)

	Map_State :: struct {
		done, ok: bool,
	}
	state: Map_State
	wgpu.BufferMapAsync(staging, {.Read}, 0, uint(size), {callback = on_map, userdata1 = &state})
	on_map :: proc "c" (
		status: wgpu.MapAsyncStatus,
		message: string,
		userdata1, userdata2: rawptr,
	) {
		st := (^Map_State)(userdata1)
		st.done = true
		st.ok = status == .Success
	}
	for !state.done {
		wgpu.DevicePoll(r.device, true)
	}
	if !state.ok {
		return nil, 0, 0
	}
	mapped := wgpu.BufferGetConstMappedRange(staging, 0, uint(size))
	width, height = int(r.width), int(r.height)
	pixels = make([]u8, width * height * 4, allocator)
	bgra := r.format == .BGRA8Unorm || r.format == .BGRA8UnormSrgb
	for y in 0 ..< height {
		src := mapped[y * row:][:width * 4]
		dst := pixels[y * width * 4:][:width * 4]
		copy(dst, src)
		if bgra {
			for x in 0 ..< width {
				dst[x * 4], dst[x * 4 + 2] = dst[x * 4 + 2], dst[x * 4]
			}
		}
	}
	wgpu.BufferUnmap(staging)
	return
}
