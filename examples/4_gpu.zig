const std = @import("std");
const clb = @import("columbus");
const way = clb.way.protocol.wayland;
const xdg_shell = clb.way.protocol.xdg_shell;
const meta = clb.meta;
const types = clb.way.types;

// Generate using [EGL bindings](https://github.com/KhronosGroup/EGL-Registry/blob/main/api/egl.xml)
const EGL = struct {
    const Display = ?*anyopaque;
    const Context = ?*anyopaque;
    const Surface = ?*anyopaque;
    const Config = ?*anyopaque;
    const Boolean = u32;
    const int = i32;

    const DEFAULT_DISPLAY: ?*anyopaque = null;
    const PLATFORM_SURFACELESS_MESA: u32 = 0x31DD;
    const OPENGL_ES_API: u32 = 0x30A0;
    const OPENGL_ES2_BIT: u32 = 0x0004;
    const PBUFFER_BIT: u32 = 0x0001;
    const RED_SIZE: u32 = 0x3024;
    const GREEN_SIZE: u32 = 0x3025;
    const BLUE_SIZE: u32 = 0x3026;
    const ALPHA_SIZE: u32 = 0x3028;
    const SURFACE_TYPE: u32 = 0x3033;
    const RENDERABLE_TYPE: u32 = 0x3040;
    const NONE: u32 = 0x3038;
    const WIDTH: u32 = 0x3057;
    const HEIGHT: u32 = 0x3056;
    const CONTEXT_CLIENT_VERSION: u32 = 0x3098;
    const GetPlatformDisplayFn = *const fn (u32, ?*anyopaque, ?[*]const EGL.int) callconv(.c) EGL.Display;
    const InitializeFn = *const fn (EGL.Display, ?*EGL.int, ?*EGL.int) callconv(.c) EGL.Boolean;
    const BindApiFn = *const fn (u32) callconv(.c) EGL.Boolean;
    const ChooseConfigFn = *const fn (EGL.Display, ?[*]const EGL.int, ?[*]EGL.Config, EGL.int, ?*EGL.int) callconv(.c) EGL.Boolean;
    const CreateContextFn = *const fn (EGL.Display, EGL.Config, EGL.Context, ?[*]const EGL.int) callconv(.c) EGL.Context;
    const CreatePbufferSurfaceFn = *const fn (EGL.Display, EGL.Config, ?[*]const EGL.int) callconv(.c) EGL.Surface;
    const MakeCurrentFn = *const fn (EGL.Display, EGL.Surface, EGL.Surface, EGL.Context) callconv(.c) EGL.Boolean;
    const SwapBuffersFn = *const fn (EGL.Display, EGL.Surface) callconv(.c) EGL.Boolean;
    const GetErrorFn = *const fn () callconv(.c) EGL.int;
    const TerminateFn = *const fn (EGL.Display) callconv(.c) EGL.Boolean;
    const DestroySurfaceFn = *const fn (EGL.Display, EGL.Surface) callconv(.c) EGL.Boolean;
    GetPlatformDisplay: GetPlatformDisplayFn,
    Initialize: InitializeFn,
    BindAPI: BindApiFn,
    ChooseConfig: ChooseConfigFn,
    CreateContext: CreateContextFn,
    CreatePbufferSurface: CreatePbufferSurfaceFn,
    MakeCurrent: MakeCurrentFn,
    SwapBuffers: SwapBuffersFn,
    GetError: GetErrorFn,
    Terminate: TerminateFn,
    DestroySurface: DestroySurfaceFn,

    pub fn load(lib: *std.DynLib) @This() {
        return .{
            .GetPlatformDisplay = lib.lookup(GetPlatformDisplayFn, "eglGetPlatformDisplayEXT") orelse
                (lib.lookup(GetPlatformDisplayFn, "eglGetPlatformDisplay") orelse
                    @panic("eglGetPlatformDisplay not found in libEGL")),
            .Initialize = lib.lookup(InitializeFn, "eglInitialize").?,
            .BindAPI = lib.lookup(BindApiFn, "eglBindAPI").?,
            .ChooseConfig = lib.lookup(ChooseConfigFn, "eglChooseConfig").?,
            .CreateContext = lib.lookup(CreateContextFn, "eglCreateContext").?,
            .CreatePbufferSurface = lib.lookup(CreatePbufferSurfaceFn, "eglCreatePbufferSurface").?,
            .MakeCurrent = lib.lookup(MakeCurrentFn, "eglMakeCurrent").?,
            .SwapBuffers = lib.lookup(SwapBuffersFn, "eglSwapBuffers").?,
            .GetError = lib.lookup(GetErrorFn, "eglGetError").?,
            .Terminate = lib.lookup(TerminateFn, "eglTerminate").?,
            .DestroySurface = lib.lookup(DestroySurfaceFn, "eglDestroySurface").?,
        };
    }
};

// Generate using [GL bindings](https://github.com/KhronosGroup/OpenGL-Registry/blob/main/xml/gl.xml)
const GL = struct {
    const uint = u32;
    const int = i32;
    const @"enum" = u32;
    const sizei = i32;
    const bitfield = u32;
    const boolean = u8;
    const float = f32;
    const COLOR_BUFFER_BIT: u32 = 0x00004000;
    const ARRAY_BUFFER: u32 = 0x8892;
    const FLOAT: u32 = 0x1406;
    const TRIANGLES: u32 = 0x0004;
    const VERTEX_SHADER: u32 = 0x8B31;
    const FRAGMENT_SHADER: u32 = 0x8B30;
    const COMPILE_STATUS: u32 = 0x8B81;
    const LINK_STATUS: u32 = 0x8B82;
    const STATIC_DRAW: u32 = 0x88E4;
    const RGBA: u32 = 0x1908;
    const UNSIGNED_BYTE: u32 = 0x1401;
    const PACK_ALIGNMENT: u32 = 0x0D05;
    const CreateShaderFn = *const fn (GL.@"enum") callconv(.c) GL.uint;
    const ShaderSourceFn = *const fn (GL.uint, GL.sizei, [*]const [*]const u8, ?[*]const GL.int) callconv(.c) void;
    const CompileShaderFn = *const fn (GL.uint) callconv(.c) void;
    const GetShaderivFn = *const fn (GL.uint, GL.@"enum", *GL.int) callconv(.c) void;
    const GetShaderInfoLogFn = *const fn (GL.uint, GL.sizei, *GL.sizei, [*]u8) callconv(.c) void;
    const DeleteShaderFn = *const fn (GL.uint) callconv(.c) void;
    const CreateProgramFn = *const fn () callconv(.c) GL.uint;
    const AttachShaderFn = *const fn (GL.uint, GL.uint) callconv(.c) void;
    const LinkProgramFn = *const fn (GL.uint) callconv(.c) void;
    const GetProgramivFn = *const fn (GL.uint, GL.@"enum", *GL.int) callconv(.c) void;
    const GetProgramInfoLogFn = *const fn (GL.uint, GL.sizei, *GL.sizei, [*]u8) callconv(.c) void;
    const DeleteProgramFn = *const fn (GL.uint) callconv(.c) void;
    const UseProgramFn = *const fn (GL.uint) callconv(.c) void;
    const GetUniformLocationFn = *const fn (GL.uint, [*:0]const u8) callconv(.c) GL.int;
    const GetAttribLocationFn = *const fn (GL.uint, [*:0]const u8) callconv(.c) GL.int;
    const GenBuffersFn = *const fn (GL.sizei, *GL.uint) callconv(.c) void;
    const BindBufferFn = *const fn (GL.@"enum", GL.uint) callconv(.c) void;
    const BufferDataFn = *const fn (GL.@"enum", isize, *const anyopaque, GL.@"enum") callconv(.c) void;
    const VertexAttribPointerFn = *const fn (GL.uint, GL.int, GL.@"enum", GL.boolean, GL.sizei, ?*const anyopaque) callconv(.c) void;
    const EnableVertexAttribArrayFn = *const fn (GL.uint) callconv(.c) void;
    const Uniform1fFn = *const fn (GL.int, GL.float) callconv(.c) void;
    const DrawArraysFn = *const fn (GL.@"enum", GL.int, GL.sizei) callconv(.c) void;
    const ReadPixelsFn = *const fn (GL.int, GL.int, GL.sizei, GL.sizei, GL.@"enum", GL.@"enum", ?*anyopaque) callconv(.c) void;
    const GetStringFn = *const fn (GL.@"enum") callconv(.c) ?[*:0]const u8;
    const ClearColorFn = *const fn (GL.float, GL.float, GL.float, GL.float) callconv(.c) void;
    const ClearFn = *const fn (GL.bitfield) callconv(.c) void;
    const ViewportFn = *const fn (GL.int, GL.int, GL.sizei, GL.sizei) callconv(.c) void;
    const PixelStoreiFn = *const fn (GL.@"enum", GL.int) callconv(.c) void;
    const DeleteBuffersFn = *const fn (GL.sizei, *GL.uint) callconv(.c) void;
    CreateShader: CreateShaderFn,
    ShaderSource: ShaderSourceFn,
    CompileShader: CompileShaderFn,
    GetShaderiv: GetShaderivFn,
    GetShaderInfoLog: GetShaderInfoLogFn,
    DeleteShader: DeleteShaderFn,
    CreateProgram: CreateProgramFn,
    AttachShader: AttachShaderFn,
    LinkProgram: LinkProgramFn,
    GetProgramiv: GetProgramivFn,
    GetProgramInfoLog: GetProgramInfoLogFn,
    DeleteProgram: DeleteProgramFn,
    UseProgram: UseProgramFn,
    GetUniformLocation: GetUniformLocationFn,
    GetAttribLocation: GetAttribLocationFn,
    GenBuffers: GenBuffersFn,
    BindBuffer: BindBufferFn,
    BufferData: BufferDataFn,
    VertexAttribPointer: VertexAttribPointerFn,
    EnableVertexAttribArray: EnableVertexAttribArrayFn,
    Uniform1f: Uniform1fFn,
    DrawArrays: DrawArraysFn,
    ReadPixels: ReadPixelsFn,
    GetString: GetStringFn,
    ClearColor: ClearColorFn,
    Clear: ClearFn,
    Viewport: ViewportFn,
    PixelStorei: PixelStoreiFn,
    DeleteBuffers: DeleteBuffersFn,
    pub fn load(lib: *std.DynLib) @This() {
        return .{
            .CreateShader = lib.lookup(CreateShaderFn, "glCreateShader").?,
            .ShaderSource = lib.lookup(ShaderSourceFn, "glShaderSource").?,
            .CompileShader = lib.lookup(CompileShaderFn, "glCompileShader").?,
            .GetShaderiv = lib.lookup(GetShaderivFn, "glGetShaderiv").?,
            .GetShaderInfoLog = lib.lookup(GetShaderInfoLogFn, "glGetShaderInfoLog").?,
            .DeleteShader = lib.lookup(DeleteShaderFn, "glDeleteShader").?,
            .CreateProgram = lib.lookup(CreateProgramFn, "glCreateProgram").?,
            .AttachShader = lib.lookup(AttachShaderFn, "glAttachShader").?,
            .LinkProgram = lib.lookup(LinkProgramFn, "glLinkProgram").?,
            .GetProgramiv = lib.lookup(GetProgramivFn, "glGetProgramiv").?,
            .GetProgramInfoLog = lib.lookup(GetProgramInfoLogFn, "glGetProgramInfoLog").?,
            .DeleteProgram = lib.lookup(DeleteProgramFn, "glDeleteProgram").?,
            .UseProgram = lib.lookup(UseProgramFn, "glUseProgram").?,
            .GetUniformLocation = lib.lookup(GetUniformLocationFn, "glGetUniformLocation").?,
            .GetAttribLocation = lib.lookup(GetAttribLocationFn, "glGetAttribLocation").?,
            .GenBuffers = lib.lookup(GenBuffersFn, "glGenBuffers").?,
            .BindBuffer = lib.lookup(BindBufferFn, "glBindBuffer").?,
            .BufferData = lib.lookup(BufferDataFn, "glBufferData").?,
            .VertexAttribPointer = lib.lookup(VertexAttribPointerFn, "glVertexAttribPointer").?,
            .EnableVertexAttribArray = lib.lookup(EnableVertexAttribArrayFn, "glEnableVertexAttribArray").?,
            .Uniform1f = lib.lookup(Uniform1fFn, "glUniform1f").?,
            .DrawArrays = lib.lookup(DrawArraysFn, "glDrawArrays").?,
            .ReadPixels = lib.lookup(ReadPixelsFn, "glReadPixels").?,
            .GetString = lib.lookup(GetStringFn, "glGetString").?,
            .ClearColor = lib.lookup(ClearColorFn, "glClearColor").?,
            .Clear = lib.lookup(ClearFn, "glClear").?,
            .Viewport = lib.lookup(ViewportFn, "glViewport").?,
            .PixelStorei = lib.lookup(PixelStoreiFn, "glPixelStorei").?,
            .DeleteBuffers = lib.lookup(DeleteBuffersFn, "glDeleteBuffers").?,
        };
    }
};

const vert_src =
    \\attribute vec2 a_pos;
    \\varying vec2 v_uv;
    \\void main() {
    \\    v_uv = a_pos * 0.5 + 0.5;
    \\    gl_Position = vec4(a_pos, 0.0, 1.0);
    \\}
;

const frag_src =
    \\precision mediump float;
    \\varying vec2 v_uv;
    \\uniform float u_time;
    \\void main() {
    \\    // animated cosine palette (Inigo Quilez style)
    \\    vec3 col = 0.5 + 0.5 * cos(u_time + v_uv.xyx + vec3(0.0, 2.0, 4.0));
    \\    gl_FragColor = vec4(col, 1.0);
    \\}
;

fn compileShader(gl: GL, kind: GL.@"enum", src: [:0]const u8) GL.uint {
    const sh = gl.CreateShader(kind);
    var ptrs = [_][*]const u8{src.ptr};
    gl.ShaderSource(sh, 1, &ptrs, null);
    gl.CompileShader(sh);
    var ok: GL.int = 0;
    gl.GetShaderiv(sh, GL.COMPILE_STATUS, &ok);
    if (ok == 0) {
        var log: [1024]u8 = undefined;
        var len: GL.sizei = 0;
        gl.GetShaderInfoLog(sh, @intCast(log.len), &len, &log);
        std.debug.print("Shader compile error: {s}\n", .{log[0..@intCast(len)]});
        @panic("shader compile failed");
    }
    return sh;
}

fn buildProgram(gl: GL) GL.uint {
    const vs = compileShader(gl, GL.VERTEX_SHADER, vert_src);
    const fs = compileShader(gl, GL.FRAGMENT_SHADER, frag_src);
    const prog = gl.CreateProgram();
    gl.AttachShader(prog, vs);
    gl.AttachShader(prog, fs);
    gl.LinkProgram(prog);
    var ok: GL.int = 0;
    gl.GetProgramiv(prog, GL.LINK_STATUS, &ok);
    if (ok == 0) {
        var log: [1024]u8 = undefined;
        var len: GL.sizei = 0;
        gl.GetProgramInfoLog(prog, @intCast(log.len), &len, &log);
        std.debug.print("Program link error: {s}\n", .{log[0..@intCast(len)]});
        @panic("program link failed");
    }
    gl.DeleteShader(vs);
    gl.DeleteShader(fs);
    return prog;
}

// Owns an offscreen EGL/OpenGL ES 2.0 context that renders an animated shader and writes the result into a wl_shm-compatible pixel buffer.
const Gpu = struct {
    lib: struct { egl: std.DynLib, gl: std.DynLib },
    bindings: struct { egl: EGL, gl: GL },
    dpy: EGL.Display,
    ctx: EGL.Context,
    surf: EGL.Surface,
    config: EGL.Config,
    w: i32,
    h: i32,
    program: GL.uint,
    u_time: GL.int,
    a_pos: GL.int,
    vbo: GL.uint,
    readbuf: []u8,

    pub fn init(w: i32, h: i32) !Gpu {
        var lib_egl = std.DynLib.open("libEGL.so.1") catch
            @panic("Failed to load libEGL.so.1 (run inside the nix dev shell: `nix develop`)");
        var lib_gl = std.DynLib.open("libGLESv2.so.2") catch
            @panic("Failed to load libGLESv2.so.2 (run inside the nix dev shell: `nix develop`)");

        const egl = EGL.load(&lib_egl);
        const gl = GL.load(&lib_gl);

        const dpy = egl.GetPlatformDisplay(EGL.PLATFORM_SURFACELESS_MESA, EGL.DEFAULT_DISPLAY, null);
        if (dpy == null) @panic("eglGetPlatformDisplay (surfaceless) failed");

        var maj: EGL.int = 0;
        var min: EGL.int = 0;
        if (egl.Initialize(dpy, &maj, &min) == 0)
            @panic("eglInitialize failed");
        if (egl.BindAPI(EGL.OPENGL_ES_API) == 0)
            @panic("eglBindAPI(EGL_OPENGL_ES_API) failed");

        const attribs = [_]EGL.int{
            EGL.SURFACE_TYPE,    EGL.PBUFFER_BIT,
            EGL.RENDERABLE_TYPE, EGL.OPENGL_ES2_BIT,
            EGL.RED_SIZE,        8,
            EGL.GREEN_SIZE,      8,
            EGL.BLUE_SIZE,       8,
            EGL.ALPHA_SIZE,      8,
            EGL.NONE,
        };
        var config: [1]EGL.Config = .{null};
        var num_config: EGL.int = 0;
        if (egl.ChooseConfig(dpy, &attribs, &config, 1, &num_config) == 0 or num_config == 0)
            @panic("eglChooseConfig failed");
        const cfg = config[0];
        if (cfg == null) @panic("eglChooseConfig returned no config");

        const ctx_attribs = [_]EGL.int{ EGL.CONTEXT_CLIENT_VERSION, 2, EGL.NONE };
        const ctx = egl.CreateContext(dpy, cfg, null, &ctx_attribs);
        if (ctx == null) @panic("eglCreateContext failed");

        const pb_attribs = [_]EGL.int{ EGL.WIDTH, w, EGL.HEIGHT, h, EGL.NONE };
        const surf = egl.CreatePbufferSurface(dpy, cfg, &pb_attribs);
        if (surf == null) @panic("eglCreatePbufferSurface failed");

        if (egl.MakeCurrent(dpy, surf, surf, ctx) == 0)
            @panic("eglMakeCurrent failed");

        if (gl.GetString(0x1F01)) |r|
            std.debug.print("GPU renderer: {s}\n", .{r});
        if (gl.GetString(0x1F02)) |v|
            std.debug.print("GL version: {s}\n", .{v});

        const program = buildProgram(gl);
        const u_time = gl.GetUniformLocation(program, "u_time");
        const a_pos = gl.GetAttribLocation(program, "a_pos");

        var vbo: GL.uint = 0;
        gl.GenBuffers(1, &vbo);
        gl.BindBuffer(GL.ARRAY_BUFFER, vbo);
        const verts = [_]GL.float{ -1, -1, 3, -1, -1, 3 }; // fullscreen triangle
        gl.BufferData(GL.ARRAY_BUFFER, @intCast(verts.len * @sizeOf(GL.float)), &verts, GL.STATIC_DRAW);

        gl.PixelStorei(GL.PACK_ALIGNMENT, 1);
        gl.Viewport(0, 0, w, h);

        const readbuf = try std.heap.page_allocator.alloc(u8, @intCast(w * h * 4));

        return .{
            .lib = .{ .egl = lib_egl, .gl = lib_gl },
            .bindings = .{ .egl = egl, .gl = gl },
            .dpy = dpy,
            .ctx = ctx,
            .surf = surf,
            .config = cfg,
            .w = w,
            .h = h,
            .program = program,
            .u_time = u_time,
            .a_pos = a_pos,
            .vbo = vbo,
            .readbuf = readbuf,
        };
    }

    pub fn resize(self: *Gpu, w: i32, h: i32) void {
        if (self.w == w and self.h == h) return;
        _ = self.bindings.egl.DestroySurface(self.dpy, self.surf);
        const pb = [_]EGL.int{ EGL.WIDTH, w, EGL.HEIGHT, h, EGL.NONE };
        const surf = self.bindings.egl.CreatePbufferSurface(self.dpy, self.config, &pb);
        if (surf == null) @panic("eglCreatePbufferSurface failed on resize");
        if (self.bindings.egl.MakeCurrent(self.dpy, surf, surf, self.ctx) == 0) @panic("eglMakeCurrent failed on resize");
        self.surf = surf;
        std.heap.page_allocator.free(self.readbuf);
        self.readbuf = std.heap.page_allocator.alloc(u8, @intCast(w * h * 4)) catch @panic("oom resizing gpu readbuf");
        self.w = w;
        self.h = h;
    }

    pub fn render(self: *Gpu, time: f32, out: []FrameBuf.Pixel) void {
        const gl = self.bindings.gl;
        gl.ClearColor(0, 0, 0, 1);
        gl.Clear(GL.COLOR_BUFFER_BIT);
        gl.UseProgram(self.program);
        gl.BindBuffer(GL.ARRAY_BUFFER, self.vbo);
        gl.VertexAttribPointer(@intCast(self.a_pos), 2, GL.FLOAT, 0, 0, null);
        gl.EnableVertexAttribArray(@intCast(self.a_pos));
        gl.Uniform1f(self.u_time, time);
        gl.DrawArrays(GL.TRIANGLES, 0, 3);
        gl.ReadPixels(0, 0, self.w, self.h, GL.RGBA, GL.UNSIGNED_BYTE, self.readbuf.ptr);

        // (little-endian 0xAARRGGBB). Swap R and B.
        for (0..out.len) |i| {
            const r = self.readbuf[4 * i + 0];
            const g = self.readbuf[4 * i + 1];
            const b = self.readbuf[4 * i + 2];
            const a = self.readbuf[4 * i + 3];
            out[i] = [4]u8{ b, g, r, a };
        }
    }

    pub fn deinit(self: *Gpu) void {
        std.heap.page_allocator.free(self.readbuf);
        _ = self.bindings.egl.Terminate(self.dpy);
        self.lib.egl.close();
        self.lib.gl.close();
    }
};

pub inline fn initial(Op: type, x: Op, args: anytype) bool {
    switch (Op) {
        way.wl_registry.Event.global => {
            args.reg_binder.bind(x, way.wl_compositor, args.wl_compositor.id);
            args.reg_binder.bind(x, xdg_shell.xdg_wm_base, args.xdg_wm_base.id);
            args.reg_binder.bind(x, way.wl_shm, args.wl_shm.id);
            args.reg_binder.bind(x, way.wl_seat, args.wl_seat.id);
            // std.debug.print("global name: {} version: {} interface: {f}\n", .{ x.name, x.version, x.interface });
        },
        way.wl_callback.Event.done => {
            std.debug.print("done: {}\n", .{x.callback_data});
            return false;
        },
        else => std.debug.print("Ignored Msg {s}{}\n", .{ @typeName(Op), x }),
    }
    return true;
}
pub inline fn configure(Op: type, x: Op, args: anytype) bool {
    switch (Op) {
        xdg_shell.xdg_surface.Event.configure => {
            args.con.io.sender.push(args.xdg_surface, xdg_shell.xdg_surface.Request.ack_configure{ .serial = x.serial });
            return false;
        },
        way.wl_display.Event.Error => std.debug.print("Error: {f}\n", .{x.message}),
        else => std.debug.print("Ignored Msg {s}{}\n", .{ @typeName(Op), x }),
    }
    return true;
}

const FrameBuf = struct {
    const Pixel = [4]u8;
    fd: std.os.linux.fd_t,
    max: [2]i32,
    byte_size: i32,
    mem: []u8,
    w: i32,
    h: i32,
    pixels: []Pixel,
    pub fn init(max: [2]i32) @This() {
        const byte_size: i32 = max[0] * max[1] * 4;
        const fd: std.os.linux.fd_t = @intCast(std.os.linux.memfd_create("framebuffer", 0));
        _ = std.os.linux.ftruncate(fd, byte_size);
        const addr = std.os.linux.mmap(null, @intCast(byte_size), .{ .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
        const mem: []u8 = @as([*]u8, @ptrFromInt(addr))[0..@intCast(byte_size)];
        return .{ .fd = fd, .max = max, .byte_size = byte_size, .mem = mem, .w = 0, .h = 0, .pixels = &[_]Pixel{} };
    }
    pub fn resize(self: *@This(), w: i32, h: i32) void {
        self.w = w;
        self.h = h;
        const n: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h));
        self.pixels = std.mem.bytesAsSlice(Pixel, self.mem[0 .. n * 4]);
        @memset(self.pixels, [4]u8{ 0, 0, 0, 0xFF });
    }
    pub fn deinit(self: @This()) void {
        _ = std.os.linux.munmap(@ptrCast(@alignCast(self.mem.ptr)), @intCast(self.byte_size));
        _ = std.os.linux.close(self.fd);
    }
};

pub inline fn conf_input(Op: type, x: Op, args: anytype) bool {
    switch (Op) {
        way.wl_seat.Event.name => std.debug.print("Seat name: {f}\n", .{x.name}),
        way.wl_seat.Event.capabilities => {
            std.debug.print("In capabilities\n", .{});
            if (x.capabilities.keyboard) {
                std.debug.print("keyboard\n", .{});
                args.con.io.sender.push(args.wl_seat, way.wl_seat.Request.get_keyboard{ .id = args.wl_keyboard });
            }
            if (x.capabilities.pointer) {
                std.debug.print("pointer\n", .{});
                args.con.io.sender.push(args.wl_seat, way.wl_seat.Request.get_pointer{ .id = args.wl_pointer });
            }
            if (x.capabilities.touch) {
                std.debug.print("touch\n", .{});
            }
        },
        else => std.debug.print("Ignored message: {s}{}\n", .{ @typeName(Op), x }),
    }
    return true;
}

const State = struct {
    render: bool = true,
    frame: u32 = 0,
    fb: *FrameBuf,
    gpu: *Gpu,
    wl_surface: way.wl_surface,
    xdg_surface: xdg_shell.xdg_surface,
    xdg_wm_base: xdg_shell.xdg_wm_base,
    env: *clb.Env,
    con: *clb.Connection,
    size: [2]i32,
    pending: [2]i32,
    need_resize: bool = false,
    busy: bool = true,
    wl_shm_pool: way.wl_shm_pool,
    wl_buffer: way.wl_buffer,
    last_abandoned: way.wl_buffer = .{ .id = 0 },
};
pub inline fn run(Op: type, x: Op, s: *State) bool {
    switch (Op) {
        xdg_shell.xdg_toplevel.Event.configure => {
            if (x.width > 0 and x.height > 0) {
                const w = @min(x.width, s.fb.max[0]);
                const h = @min(x.height, s.fb.max[1]);
                if (w != s.size[0] or h != s.size[1]) {
                    s.pending = [2]i32{ w, h };
                    s.need_resize = true;
                }
            }
        },
        xdg_shell.xdg_surface.Event.configure => {
            if (s.need_resize) {
                const w = s.pending[0];
                const h = s.pending[1];
                const old = s.wl_buffer;
                s.fb.resize(w, h);
                s.gpu.resize(w, h);
                if (s.last_abandoned.id != 0) {
                    s.con.io.sender.push(s.last_abandoned, way.wl_buffer.Request.destroy{});
                }
                const new_buf = s.env.new(way.wl_buffer);
                s.con.io.sender.push(s.wl_shm_pool, way.wl_shm_pool.Request.create_buffer{
                    .id = new_buf,
                    .offset = 0,
                    .width = w,
                    .height = h,
                    .stride = w * 4,
                    .format = .argb8888,
                });
                s.last_abandoned = old;
                s.wl_buffer = new_buf;
                s.size = s.pending;
                s.need_resize = false;
                s.render = true;
            }
            s.con.io.sender.push(s.xdg_surface, xdg_shell.xdg_surface.Request.ack_configure{ .serial = x.serial });
            s.con.send();
        },
        way.wl_display.Event.Error => std.debug.print("Error: {f}\n", .{x.message}),
        way.wl_buffer.Event.release => {
            // Compositor is done with the buffer; we may render into it again.
            s.busy = false;
            s.render = true;
        },
        way.wl_display.Event.delete_id => s.env.delete(x.id),
        xdg_shell.xdg_toplevel.Event.close => {
            std.debug.print("Closing window!\n", .{});
            return false;
        },
        xdg_shell.xdg_wm_base.Event.ping => {
            s.con.io.sender.push(s.xdg_wm_base, xdg_shell.xdg_wm_base.Request.pong{ .serial = x.serial });
            s.con.send();
        },
        way.wl_keyboard.Event.key => std.debug.print("Entered: {}\n", .{x.key}),
        way.wl_pointer.Event.frame => {},
        way.wl_pointer.Event.motion => {},
        else => std.debug.print("Ignored Msg {s}{}\n", .{ @typeName(Op), x }),
    }

    if (s.render and !s.busy) {
        s.frame += 1;
        const t = @as(f32, @floatFromInt(s.frame)) / 60.0;
        s.gpu.render(t, s.fb.pixels);
        s.con.io.sender.push(s.wl_surface, way.wl_surface.Request.attach{ .buffer = s.wl_buffer.id, .x = 0, .y = 0 });
        s.con.io.sender.push(s.wl_surface, way.wl_surface.Request.damage{ .x = 0, .y = 0, .width = std.math.maxInt(i32), .height = std.math.maxInt(i32) });
        s.con.io.sender.push(s.wl_surface, way.wl_surface.Request.commit{});
        s.con.send();
        s.busy = true;
        s.render = false;
    }
    return true;
}

pub fn main(init: std.process.Init) !void {
    var env = clb.Env.init();
    const display = env.new(way.wl_display);
    const registry = env.new(way.wl_registry);
    const wl_callback = env.new(way.wl_callback);
    var con = try clb.Connection.initDefault(init);
    con.io.sender.push(display, way.wl_display.Request.get_registry{ .registry = registry });
    con.io.sender.push(display, way.wl_display.Request.sync{ .callback = wl_callback });
    con.send();
    var reg_binder = clb.RegistryBinder.init(&con, registry);

    const wl_compositor = env.new(way.wl_compositor);
    const wl_shm = env.new(way.wl_shm);
    const xdg_wm_base = env.new(xdg_shell.xdg_wm_base);
    const wl_seat = env.new(way.wl_seat);
    try clb.loop(init.io, &con, &env, .{
        .reg_binder = &reg_binder,
        .wl_compositor = wl_compositor,
        .xdg_wm_base = xdg_wm_base,
        .wl_shm = wl_shm,
        .wl_seat = wl_seat,
    }, .{initial}, clb.wait_for(.fromMilliseconds(16)));

    const wl_keyboard = env.new(way.wl_keyboard);
    const wl_pointer = env.new(way.wl_pointer);
    try clb.loop(init.io, &con, &env, .{
        .wl_seat = wl_seat,
        .wl_keyboard = wl_keyboard,
        .wl_pointer = wl_pointer,
        .con = &con,
    }, .{conf_input}, clb.alwaysFalse);
    con.send();

    const wl_surface = env.new(way.wl_surface);
    const xdg_surface = env.new(xdg_shell.xdg_surface);
    const xdg_toplenel = env.new(xdg_shell.xdg_toplevel);
    con.io.sender.push(wl_compositor, way.wl_compositor.Request.create_surface{ .id = wl_surface });
    con.io.sender.push(xdg_wm_base, xdg_shell.xdg_wm_base.Request.get_xdg_surface{ .id = xdg_surface, .surface = wl_surface.id });
    con.io.sender.push(xdg_surface, xdg_shell.xdg_surface.Request.get_toplevel{ .id = xdg_toplenel });
    con.io.sender.push(wl_surface, way.wl_surface.Request.commit{});
    con.send();
    try std.Io.sleep(init.io, .fromMilliseconds(50), .real); // too fast otherwise

    try clb.loop(init.io, &con, &env, .{
        .con = &con,
        .xdg_surface = xdg_surface,
    }, .{configure}, clb.alwaysFalse);

    const MAX: [2]i32 = .{ 4096, 4096 };
    const INITIAL: [2]i32 = .{ 256, 256 };

    var fb = FrameBuf.init(MAX);
    fb.resize(INITIAL[0], INITIAL[1]);

    const wl_shm_pool = env.new(way.wl_shm_pool);
    const wl_buffer = env.new(way.wl_buffer);
    // con.io.sender.push(wl_compositor, way.wl_compositor.Request.create_surface{ .id = wl_surface });
    con.io.sender.push(wl_shm, way.wl_shm.Request.create_pool{
        .id = wl_shm_pool,
        .fd = .{ .fd = fb.fd },
        .size = fb.byte_size,
    });
    con.io.sender.push(wl_shm_pool, way.wl_shm_pool.Request.create_buffer{
        .id = wl_buffer,
        .offset = 0,
        .width = INITIAL[0],
        .height = INITIAL[1],
        .stride = INITIAL[0] * 4,
        .format = .argb8888,
    });
    con.io.sender.push(wl_surface, way.wl_surface.Request.attach{
        .buffer = wl_buffer.id,
        .x = 0,
        .y = 0,
    });
    con.io.sender.push(wl_surface, way.wl_surface.Request.damage{ .x = 0, .y = 0, .width = std.math.maxInt(i32), .height = std.math.maxInt(i32) });
    con.io.sender.push(wl_surface, way.wl_surface.Request.commit{});
    con.send();

    var gpu = try Gpu.init(INITIAL[0], INITIAL[1]);
    defer gpu.deinit();

    var state = State{
        .fb = &fb,
        .gpu = &gpu,
        .wl_surface = wl_surface,
        .xdg_surface = xdg_surface,
        .xdg_wm_base = xdg_wm_base,
        .env = &env,
        .con = &con,
        .size = INITIAL,
        .pending = INITIAL,
        .need_resize = false,
        .wl_shm_pool = wl_shm_pool,
        .wl_buffer = wl_buffer,
    };
    try clb.loop(init.io, &con, &env, &state, .{run}, clb.wait_for(.fromMilliseconds(16)));
}
// const xkb_keycode = keycode + 8;
