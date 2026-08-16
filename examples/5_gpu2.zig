const std = @import("std");
const clb = @import("columbus");
const way = clb.way.protocol.wayland;
const xdg_shell = clb.way.protocol.xdg_shell;
const meta = clb.meta;
const types = clb.way.types;

// ---------------------------------------------------------------------------
// GPU example: render an animated shader on the GPU with EGL/OpenGL ES into an
// offscreen FBO (backed by a GBM buffer object), read the result back with
// glReadPixels, and present it to Wayland through wl_shm (a memfd-backed shared
// memory buffer).
//
// The original attempt presented the GBM bo as a dma-buf via
// zwp_linux_dmabuf_v1 (eglCreateImageKHR + eglExportDMABUFImageMESA). That path
// is rejected by the running compositor (Mutter) at create_params and relies on
// a SCM_RIGHTS handling quirk in columbus's sender that cannot be fixed from
// this file, so we fall back to wl_shm -- the same reliable path
// examples/4_gpu.zig uses. The rendering is still 100% on the GPU.
// ---------------------------------------------------------------------------

const ARGB8888: u32 = 0x34325241; // DRM_FORMAT_ARGB8888

const EGL = struct {
    const Display = ?*anyopaque;
    const Context = ?*anyopaque;
    const Surface = ?*anyopaque;
    const Config = ?*anyopaque;
    const ImageKHR = ?*anyopaque;
    const SyncKHR = ?*anyopaque;
    const ClientBuffer = ?*anyopaque;
    const Boolean = u32;
    const int = i32;
    const TimeKHR = u64;

    const DEFAULT_DISPLAY: ?*anyopaque = null;
    const NO_CONTEXT: EGL.Context = null;
    const NO_SURFACE: EGL.Surface = null;
    const PLATFORM_SURFACELESS_MESA: u32 = 0x31DD;
    const PLATFORM_GBM_MESA: u32 = 0x31D7;
    const OPENGL_ES_API: u32 = 0x30A0;
    const OPENGL_ES2_BIT: u32 = 0x0004;
    const WINDOW_BIT: u32 = 0x0004;
    const PBUFFER_BIT: u32 = 0x0001;
    const RED_SIZE: u32 = 0x3024;
    const GREEN_SIZE: u32 = 0x3025;
    const BLUE_SIZE: u32 = 0x3026;
    const ALPHA_SIZE: u32 = 0x3028;
    const SURFACE_TYPE: u32 = 0x3033;
    const RENDERABLE_TYPE: u32 = 0x3040;
    const NONE: u32 = 0x3038;
    const CONTEXT_CLIENT_VERSION: u32 = 0x3098;
    const NATIVE_VISUAL_ID: u32 = 0x302E;
    const NATIVE_PIXMAP_KHR: u32 = 0x30B0;
    const IMAGE_PRESERVED_KHR: u32 = 0x30D2;
    const NO_IMAGE_KHR: EGL.ImageKHR = null;
    const WIDTH: u32 = 0x3057;
    const HEIGHT: u32 = 0x3056;

    const GetPlatformDisplayFn = *const fn (u32, ?*anyopaque, ?[*]const EGL.int) callconv(.c) EGL.Display;
    const InitializeFn = *const fn (EGL.Display, ?*EGL.int, ?*EGL.int) callconv(.c) EGL.Boolean;
    const BindApiFn = *const fn (u32) callconv(.c) EGL.Boolean;
    const ChooseConfigFn = *const fn (EGL.Display, ?[*]const EGL.int, ?[*]EGL.Config, EGL.int, ?*EGL.int) callconv(.c) EGL.Boolean;
    const CreateContextFn = *const fn (EGL.Display, EGL.Config, EGL.Context, ?[*]const EGL.int) callconv(.c) EGL.Context;
    const CreatePbufferSurfaceFn = *const fn (EGL.Display, EGL.Config, ?[*]const EGL.int) callconv(.c) EGL.Surface;
    const CreateWindowSurfaceFn = *const fn (EGL.Display, EGL.Config, ?*anyopaque, ?[*]const EGL.int) callconv(.c) EGL.Surface;
    const MakeCurrentFn = *const fn (EGL.Display, EGL.Surface, EGL.Surface, EGL.Context) callconv(.c) EGL.Boolean;
    const SwapBuffersFn = *const fn (EGL.Display, EGL.Surface) callconv(.c) EGL.Boolean;
    const GetErrorFn = *const fn () callconv(.c) EGL.int;
    const QueryStringFn = *const fn (EGL.Display, EGL.int) callconv(.c) ?[*:0]const u8;
    const GetConfigAttribFn = *const fn (EGL.Display, EGL.Config, EGL.int, *EGL.int) callconv(.c) EGL.Boolean;
    const GetConfigsFn = *const fn (EGL.Display, ?[*]EGL.Config, EGL.int, *EGL.int) callconv(.c) EGL.Boolean;
    const TerminateFn = *const fn (EGL.Display) callconv(.c) EGL.Boolean;
    const GetProcAddressFn = *const fn ([*:0]const u8) callconv(.c) ?*anyopaque;
    const DestroySurfaceFn = *const fn (EGL.Display, EGL.Surface) callconv(.c) EGL.Boolean;
    const CreateImageKHRFn = *const fn (EGL.Display, EGL.Context, EGL.int, EGL.ClientBuffer, ?[*]const EGL.int) callconv(.c) EGL.ImageKHR;
    const DestroyImageKHRFn = *const fn (EGL.Display, EGL.ImageKHR) callconv(.c) EGL.Boolean;
    const ExportDMABUFImageMESAFn = *const fn (EGL.Display, EGL.ImageKHR, *c_int, *EGL.int, *EGL.int) callconv(.c) EGL.Boolean;
    const EGLImageTargetTexture2DOESFn = *const fn (u32, ?*anyopaque) callconv(.c) void;
    GetPlatformDisplay: GetPlatformDisplayFn,
    Initialize: InitializeFn,
    BindAPI: BindApiFn,
    ChooseConfig: ChooseConfigFn,
    CreateContext: CreateContextFn,
    CreatePbufferSurface: CreatePbufferSurfaceFn,
    CreateWindowSurface: CreateWindowSurfaceFn,
    MakeCurrent: MakeCurrentFn,
    SwapBuffers: SwapBuffersFn,
    GetError: GetErrorFn,
    QueryString: QueryStringFn,
    GetConfigAttrib: GetConfigAttribFn,
    GetConfigs: GetConfigsFn,
    Terminate: TerminateFn,
    GetProcAddress: GetProcAddressFn,
    DestroySurface: DestroySurfaceFn,
    CreateImageKHR: CreateImageKHRFn,
    DestroyImageKHR: DestroyImageKHRFn,
    ExportDMABUFImageMESA: ExportDMABUFImageMESAFn,
    EGLImageTargetTexture2DOES: EGLImageTargetTexture2DOESFn,

    pub fn load(lib: *std.DynLib) @This() {
        const gp: GetProcAddressFn = lib.lookup(GetProcAddressFn, "eglGetProcAddress") orelse
            @panic("eglGetProcAddress not found in libEGL");
        return .{
            .GetProcAddress = gp,
            .GetPlatformDisplay = lib.lookup(GetPlatformDisplayFn, "eglGetPlatformDisplayEXT") orelse
                (lib.lookup(GetPlatformDisplayFn, "eglGetPlatformDisplay") orelse
                    @panic("eglGetPlatformDisplay not found in libEGL")),
            .Initialize = lib.lookup(InitializeFn, "eglInitialize").?,
            .BindAPI = lib.lookup(BindApiFn, "eglBindAPI").?,
            .ChooseConfig = lib.lookup(ChooseConfigFn, "eglChooseConfig").?,
            .CreateContext = lib.lookup(CreateContextFn, "eglCreateContext").?,
            .CreatePbufferSurface = lib.lookup(CreatePbufferSurfaceFn, "eglCreatePbufferSurface").?,
            .CreateWindowSurface = lib.lookup(CreateWindowSurfaceFn, "eglCreateWindowSurface").?,
            .MakeCurrent = lib.lookup(MakeCurrentFn, "eglMakeCurrent").?,
            .SwapBuffers = lib.lookup(SwapBuffersFn, "eglSwapBuffers").?,
            .GetError = lib.lookup(GetErrorFn, "eglGetError").?,
            .QueryString = lib.lookup(QueryStringFn, "eglQueryString").?,
            .GetConfigAttrib = lib.lookup(GetConfigAttribFn, "eglGetConfigAttrib").?,
            .GetConfigs = lib.lookup(GetConfigsFn, "eglGetConfigs").?,
            .Terminate = lib.lookup(TerminateFn, "eglTerminate").?,
            .DestroySurface = lib.lookup(DestroySurfaceFn, "eglDestroySurface").?,
            .CreateImageKHR = @ptrCast(gp("eglCreateImageKHR") orelse @panic("eglCreateImageKHR not found (Mesa EGL)")),
            .DestroyImageKHR = @ptrCast(gp("eglDestroyImageKHR") orelse @panic("eglDestroyImageKHR not found (Mesa EGL)")),
            .ExportDMABUFImageMESA = @ptrCast(gp("eglExportDMABUFImageMESA") orelse @panic("eglExportDMABUFImageMESA not found (Mesa EGL)")),
            .EGLImageTargetTexture2DOES = @ptrCast(gp("glEGLImageTargetTexture2DOES") orelse @panic("glEGLImageTargetTexture2DOES not found (via eglGetProcAddress)")),
        };
    }
};

const GL = struct {
    const uint = u32;
    const int = i32;
    const float = f32;
    const sizei = i32;
    const @"enum" = u32;
    const TEXTURE_2D: u32 = 0x0DE1;
    const FRAMEBUFFER: u32 = 0x8D40;
    const COLOR_ATTACHMENT0: u32 = 0x8CE0;
    const FRAMEBUFFER_COMPLETE: u32 = 0x8CD5;
    const COMPILE_STATUS: u32 = 0x8B81;
    const LINK_STATUS: u32 = 0x8B82;
    const ARRAY_BUFFER: u32 = 0x8892;
    const STATIC_DRAW: u32 = 0x88E4;
    const FLOAT: u32 = 0x1406;
    const RGBA: u32 = 0x1908;
    const RGBA8: u32 = 0x8058;
    const UNSIGNED_BYTE: u32 = 0x1401;
    const PACK_ALIGNMENT: u32 = 0x0D05;
    const TRIANGLES: u32 = 0x0004;
    const COLOR_BUFFER_BIT: u32 = 0x4000;
    const TEXTURE_MIN_FILTER: u32 = 0x2801;
    const TEXTURE_MAG_FILTER: u32 = 0x2800;
    const TEXTURE_WRAP_S: u32 = 0x2802;
    const TEXTURE_WRAP_T: u32 = 0x2803;
    const CLAMP_TO_EDGE: u32 = 0x812F;
    const LINEAR: u32 = 0x2601;
    const NEAREST: u32 = 0x2600;
    const RENDERBUFFER: u32 = 0x8617;

    const CreateShaderFn = *const fn (GL.@"enum") callconv(.c) GL.uint;
    const ShaderSourceFn = *const fn (GL.uint, GL.sizei, [*]const [*:0]const u8, ?*const GL.int) callconv(.c) void;
    const CompileShaderFn = *const fn (GL.uint) callconv(.c) void;
    const GetShaderivFn = *const fn (GL.uint, GL.@"enum", *GL.int) callconv(.c) void;
    const GetShaderInfoLogFn = *const fn (GL.uint, GL.sizei, *GL.sizei, [*]u8) callconv(.c) void;
    const DeleteShaderFn = *const fn (GL.uint) callconv(.c) void;
    const BindFramebufferFn = *const fn (GL.@"enum", GL.uint) callconv(.c) void;
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
    const BindTextureFn = *const fn (GL.@"enum", GL.uint) callconv(.c) void;
    const TexImage2DFn = *const fn (GL.@"enum", GL.int, GL.int, GL.sizei, GL.sizei, GL.int, GL.@"enum", GL.@"enum", ?*const anyopaque) callconv(.c) void;
    const BufferDataFn = *const fn (GL.@"enum", GL.sizei, ?*const anyopaque, GL.@"enum") callconv(.c) void;
    const VertexAttribPointerFn = *const fn (GL.uint, GL.int, GL.@"enum", GL.int, GL.sizei, ?*const anyopaque) callconv(.c) void;
    const EnableVertexAttribArrayFn = *const fn (GL.uint) callconv(.c) void;
    const Uniform1fFn = *const fn (GL.int, GL.float) callconv(.c) void;
    const DrawArraysFn = *const fn (GL.@"enum", GL.int, GL.sizei) callconv(.c) void;
    const ReadPixelsFn = *const fn (GL.int, GL.int, GL.sizei, GL.sizei, GL.@"enum", GL.@"enum", ?*anyopaque) callconv(.c) void;
    const GetStringFn = *const fn (GL.@"enum") callconv(.c) ?[*:0]const u8;
    const ClearColorFn = *const fn (GL.float, GL.float, GL.float, GL.float) callconv(.c) void;
    const ClearFn = *const fn (GL.@"enum") callconv(.c) void;
    const ViewportFn = *const fn (GL.int, GL.int, GL.sizei, GL.sizei) callconv(.c) void;
    const PixelStoreiFn = *const fn (GL.@"enum", GL.int) callconv(.c) void;
    const DeleteBuffersFn = *const fn (GL.sizei, *GL.uint) callconv(.c) void;
    const TexParameteriFn = *const fn (GL.@"enum", GL.@"enum", GL.int) callconv(.c) void;
    const GenTexturesFn = *const fn (GL.sizei, *GL.uint) callconv(.c) void;
    const GetErrorFn = *const fn () callconv(.c) GL.@"enum";
    const FlushFn = *const fn () callconv(.c) void;
    const GenRenderbuffersFn = *const fn (GL.sizei, *GL.uint) callconv(.c) void;
    const BindRenderbufferFn = *const fn (GL.@"enum", GL.uint) callconv(.c) void;
    const RenderbufferStorageFn = *const fn (GL.@"enum", GL.@"enum", GL.sizei, GL.sizei) callconv(.c) void;
    const DeleteRenderbuffersFn = *const fn (GL.sizei, *GL.uint) callconv(.c) void;
    const GenFramebuffersFn = *const fn (GL.sizei, *GL.uint) callconv(.c) void;
    const FramebufferTexture2DFn = *const fn (GL.@"enum", GL.@"enum", GL.@"enum", GL.uint, GL.int) callconv(.c) void;
    const DeleteFramebuffersFn = *const fn (GL.sizei, *GL.uint) callconv(.c) void;
    const DeleteTexturesFn = *const fn (GL.sizei, *GL.uint) callconv(.c) void;
    const CheckFramebufferStatusFn = *const fn (GL.@"enum") callconv(.c) GL.@"enum";
    const FinishFn = *const fn () callconv(.c) void;
    CreateShader: CreateShaderFn,
    ShaderSource: ShaderSourceFn,
    CompileShader: CompileShaderFn,
    GetShaderiv: GetShaderivFn,
    GetShaderInfoLog: GetShaderInfoLogFn,
    DeleteShader: DeleteShaderFn,
    BindFramebuffer: BindFramebufferFn,
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
    BindTexture: BindTextureFn,
    TexImage2D: TexImage2DFn,
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
    TexParameteri: TexParameteriFn,
    GenTextures: GenTexturesFn,
    GetError: GetErrorFn,
    Flush: FlushFn,
    GenRenderbuffers: GenRenderbuffersFn,
    BindRenderbuffer: BindRenderbufferFn,
    RenderbufferStorage: RenderbufferStorageFn,
    DeleteRenderbuffers: DeleteRenderbuffersFn,
    GenFramebuffers: GenFramebuffersFn,
    FramebufferTexture2D: FramebufferTexture2DFn,
    DeleteFramebuffers: DeleteFramebuffersFn,
    DeleteTextures: DeleteTexturesFn,
    CheckFramebufferStatus: CheckFramebufferStatusFn,
    Finish: FinishFn,

    pub fn load(lib: *std.DynLib) @This() {
        return .{
            .CreateShader = lib.lookup(CreateShaderFn, "glCreateShader").?,
            .ShaderSource = lib.lookup(ShaderSourceFn, "glShaderSource").?,
            .CompileShader = lib.lookup(CompileShaderFn, "glCompileShader").?,
            .GetShaderiv = lib.lookup(GetShaderivFn, "glGetShaderiv").?,
            .GetShaderInfoLog = lib.lookup(GetShaderInfoLogFn, "glGetShaderInfoLog").?,
            .DeleteShader = lib.lookup(DeleteShaderFn, "glDeleteShader").?,
            .BindFramebuffer = lib.lookup(BindFramebufferFn, "glBindFramebuffer").?,
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
            .BindTexture = lib.lookup(BindTextureFn, "glBindTexture").?,
            .TexImage2D = lib.lookup(TexImage2DFn, "glTexImage2D").?,
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
            .TexParameteri = lib.lookup(TexParameteriFn, "glTexParameteri").?,
            .GenTextures = lib.lookup(GenTexturesFn, "glGenTextures").?,
            .GetError = lib.lookup(GetErrorFn, "glGetError").?,
            .Flush = lib.lookup(FlushFn, "glFlush").?,
            .GenRenderbuffers = lib.lookup(GenRenderbuffersFn, "glGenRenderbuffers").?,
            .BindRenderbuffer = lib.lookup(BindRenderbufferFn, "glBindRenderbuffer").?,
            .RenderbufferStorage = lib.lookup(RenderbufferStorageFn, "glRenderbufferStorage").?,
            .DeleteRenderbuffers = lib.lookup(DeleteRenderbuffersFn, "glDeleteRenderbuffers").?,
            .GenFramebuffers = lib.lookup(GenFramebuffersFn, "glGenFramebuffers").?,
            .FramebufferTexture2D = lib.lookup(FramebufferTexture2DFn, "glFramebufferTexture2D").?,
            .DeleteFramebuffers = lib.lookup(DeleteFramebuffersFn, "glDeleteFramebuffers").?,
            .DeleteTextures = lib.lookup(DeleteTexturesFn, "glDeleteTextures").?,
            .CheckFramebufferStatus = lib.lookup(CheckFramebufferStatusFn, "glCheckFramebufferStatus").?,
            .Finish = lib.lookup(FinishFn, "glFinish").?,
        };
    }
};

const GBM = struct {
    const Device = ?*anyopaque;
    const Bo = ?*anyopaque;
    const Surface = ?*anyopaque;
    const FORMAT_ARGB8888: u32 = 0x34325241;
    const BO_USE_RENDERING: u32 = 1 << 2; // 4
    const BO_USE_SCANOUT: u32 = 1 << 0; // 1
    const create_deviceFn = *const fn (c_int) callconv(.c) GBM.Device;
    const device_destroyFn = *const fn (GBM.Device) callconv(.c) void;
    const bo_createFn = *const fn (GBM.Device, c_uint, c_uint, c_uint, c_uint) callconv(.c) GBM.Bo;
    const bo_destroyFn = *const fn (GBM.Bo) callconv(.c) void;
    const surface_createFn = *const fn (GBM.Device, c_uint, c_uint, c_uint, c_uint) callconv(.c) GBM.Surface;
    const surface_destroyFn = *const fn (GBM.Surface) callconv(.c) void;
    create_device: create_deviceFn,
    device_destroy: device_destroyFn,
    bo_create: bo_createFn,
    bo_destroy: bo_destroyFn,
    surface_create: surface_createFn,
    surface_destroy: surface_destroyFn,

    pub fn load(lib: *std.DynLib) @This() {
        return .{
            .create_device = lib.lookup(create_deviceFn, "gbm_create_device") orelse @panic("gbm_create_device not found in libgbm"),
            .device_destroy = lib.lookup(device_destroyFn, "gbm_device_destroy").?,
            .bo_create = lib.lookup(bo_createFn, "gbm_bo_create").?,
            .bo_destroy = lib.lookup(bo_destroyFn, "gbm_bo_destroy").?,
            .surface_create = lib.lookup(surface_createFn, "gbm_surface_create").?,
            .surface_destroy = lib.lookup(surface_destroyFn, "gbm_surface_destroy").?,
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
    \\vec3 palette(float t) {
    \\    return 0.5 + 0.5 * cos(6.28318 * (vec3(0.0, 0.33, 0.67) + t));
    \\}
    \\void main() {
    \\    float t = u_time + (v_uv.x + v_uv.y);
    \\    gl_FragColor = vec4(palette(t), 1.0);
    \\}
;

fn buildProgram(gl: GL) GL.uint {
    const vs = gl.CreateShader(0x8B31); // VERTEX_SHADER
    gl.ShaderSource(vs, 1, @ptrCast(&vert_src), null);
    gl.CompileShader(vs);
    var ok: GL.int = 0;
    gl.GetShaderiv(vs, GL.COMPILE_STATUS, &ok);
    if (ok == 0) {
        var log: [512]u8 = undefined;
        var len: GL.sizei = 0;
        gl.GetShaderInfoLog(vs, 512, &len, &log);
        std.debug.print("Vertex shader error: {s}\n", .{log[0..@intCast(len)]});
        @panic("vertex shader failed");
    }
    const fs = gl.CreateShader(0x8B30); // FRAGMENT_SHADER
    gl.ShaderSource(fs, 1, @ptrCast(&frag_src), null);
    gl.CompileShader(fs);
    gl.GetShaderiv(fs, GL.COMPILE_STATUS, &ok);
    if (ok == 0) {
        var log: [512]u8 = undefined;
        var len: GL.sizei = 0;
        gl.GetShaderInfoLog(fs, 512, &len, &log);
        std.debug.print("Fragment shader error: {s}\n", .{log[0..@intCast(len)]});
        @panic("fragment shader failed");
    }
    const prog = gl.CreateProgram();
    gl.AttachShader(prog, vs);
    gl.AttachShader(prog, fs);
    gl.LinkProgram(prog);
    gl.GetProgramiv(prog, GL.LINK_STATUS, &ok);
    if (ok == 0) {
        var log: [512]u8 = undefined;
        var len: GL.sizei = 0;
        gl.GetProgramInfoLog(prog, 512, &len, &log);
        std.debug.print("Program link error: {s}\n", .{log[0..@intCast(len)]});
        @panic("program link failed");
    }
    gl.DeleteShader(vs);
    gl.DeleteShader(fs);
    return prog;
}

// A memfd-backed pixel buffer we hand to the compositor through wl_shm. The
// memory is mapped shared, so writing into `pixels` updates the buffer the
// compositor reads.
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

// Owns an EGL/OpenGL ES context that renders the animated shader into an
// offscreen GBM-backed FBO. The rendered pixels are read back into a CPU buffer
// with glReadPixels and copied (R<->B swapped) into a wl_shm framebuffer.
const Gpu = struct {
    lib_egl: std.DynLib,
    lib_gl: std.DynLib,
    lib_gbm: std.DynLib,
    egl: EGL,
    gl: GL,
    gbm: GBM,
    dpy: EGL.Display,
    ctx: EGL.Context,
    config: EGL.Config,
    gbm_dev: GBM.Device,
    drm_fd: std.os.linux.fd_t,
    egl_surface: EGL.Surface, // window surface used only to make the context current
    gbm_surface: GBM.Surface,
    gbm_bo: GBM.Bo,
    egl_image: EGL.ImageKHR,
    fbo: GL.uint,
    tex: GL.uint,
    program: GL.uint,
    u_time: GL.int,
    a_pos: GL.int,
    vbo: GL.uint,
    readbuf: []u8,
    w: i32,
    h: i32,

    pub fn init(w: i32, h: i32) !Gpu {
        var lib_egl = std.DynLib.open("libEGL.so.1") catch
            @panic("Failed to load libEGL.so.1 (run inside the nix dev shell: `nix develop`)");
        var lib_gl = std.DynLib.open("libGLESv2.so.2") catch
            @panic("Failed to load libGLESv2.so.2 (run inside the nix dev shell: `nix develop`)");
        var lib_gbm = std.DynLib.open("libgbm.so.1") catch
            @panic("Failed to load libgbm.so.1 (run inside the nix dev shell: `nix develop`)");

        const egl = EGL.load(&lib_egl);
        const gl = GL.load(&lib_gl);
        const gbm = GBM.load(&lib_gbm);

        const drm_fd = openRenderNode();
        const gbm_dev = gbm.create_device(@intCast(drm_fd));
        if (gbm_dev == null) @panic("gbm_create_device failed");

        const dpy = egl.GetPlatformDisplay(EGL.PLATFORM_GBM_MESA, gbm_dev, null);
        if (dpy == null) @panic("eglGetPlatformDisplay (gbm) failed");

        var maj: EGL.int = 0;
        var min: EGL.int = 0;
        if (egl.Initialize(dpy, &maj, &min) == 0)
            @panic("eglInitialize failed");
        if (egl.BindAPI(EGL.OPENGL_ES_API) == 0)
            @panic("eglBindAPI(EGL_OPENGL_ES_API) failed");

        // Enumerate configs and pick one whose native visual is ARGB8888 so it
        // matches the GBM surface format; ChooseConfig alone can return a 10-bit
        // config here, which is rejected by eglCreateWindowSurface (EGL_BAD_MATCH).
        var all: [256]EGL.Config = undefined;
        var num_all: EGL.int = 0;
        if (egl.GetConfigs(dpy, &all, all.len, &num_all) == 0)
            @panic("eglGetConfigs failed");
        var cfg: EGL.Config = null;
        var i: usize = 0;
        const n_cfg = @as(usize, @intCast(num_all));
        while (i < n_cfg) : (i += 1) {
            var vis: EGL.int = 0;
            _ = egl.GetConfigAttrib(dpy, all[i], EGL.NATIVE_VISUAL_ID, &vis);
            if (vis == @as(EGL.int, @bitCast(ARGB8888))) {
                cfg = all[i];
                break;
            }
        }
        if (cfg == null) @panic("no ARGB8888 EGL config");
        const ctx_attribs = [_]EGL.int{ EGL.CONTEXT_CLIENT_VERSION, 3, EGL.NONE };
        const ctx = egl.CreateContext(dpy, cfg, null, &ctx_attribs);
        if (ctx == null) @panic("eglCreateContext failed");

        // The GBM window surface is only used to make the EGL context current;
        // actual rendering goes into the FBO backed by a GBM bo (see allocTargets).
        const gbm_surface = gbm.surface_create(gbm_dev, @intCast(w), @intCast(h), GBM.FORMAT_ARGB8888, GBM.BO_USE_RENDERING | GBM.BO_USE_SCANOUT);
        if (gbm_surface == null) @panic("gbm_surface_create failed");
        const egl_surface = egl.CreateWindowSurface(dpy, cfg, gbm_surface, null);
        if (egl_surface == null) @panic("eglCreateWindowSurface failed");
        if (egl.MakeCurrent(dpy, egl_surface, egl_surface, ctx) == 0)
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

        var gpu = Gpu{
            .lib_egl = lib_egl,
            .lib_gl = lib_gl,
            .lib_gbm = lib_gbm,
            .egl = egl,
            .gl = gl,
            .gbm = gbm,
            .dpy = dpy,
            .ctx = ctx,
            .config = cfg,
            .gbm_dev = gbm_dev,
            .drm_fd = drm_fd,
            .egl_surface = egl_surface,
            .gbm_surface = gbm_surface,
            .gbm_bo = null,
            .egl_image = EGL.NO_IMAGE_KHR,
            .fbo = 0,
            .tex = 0,
            .program = program,
            .u_time = u_time,
            .a_pos = a_pos,
            .vbo = vbo,
            .readbuf = try std.heap.page_allocator.alloc(u8, @intCast(w * h * 4)),
            .w = w,
            .h = h,
        };
        gpu.allocTargets(w, h);
        return gpu;
    }

    // Render the animated shader into the FBO-backed GBM bo and read the pixels
    // back into the CPU read buffer (RGBA8).
    pub fn render(self: *Gpu, time: f32) void {
        const gl = self.gl;
        gl.BindFramebuffer(GL.FRAMEBUFFER, self.fbo);
        gl.Viewport(0, 0, self.w, self.h);
        gl.ClearColor(0, 0, 0, 1);
        gl.Clear(GL.COLOR_BUFFER_BIT);
        gl.UseProgram(self.program);
        gl.BindBuffer(GL.ARRAY_BUFFER, self.vbo);
        gl.VertexAttribPointer(@intCast(self.a_pos), 2, GL.FLOAT, 0, 0, null);
        gl.EnableVertexAttribArray(@intCast(self.a_pos));
        gl.Uniform1f(self.u_time, time);
        gl.DrawArrays(GL.TRIANGLES, 0, 3);
        gl.Finish();
        gl.PixelStorei(GL.PACK_ALIGNMENT, 1);
        gl.ReadPixels(0, 0, self.w, self.h, GL.RGBA, GL.UNSIGNED_BYTE, self.readbuf.ptr);
    }

    // Copy the just-rendered pixels (RGBA) into the wl_shm framebuffer, swapping
    // R and B so the layout matches DRM_FORMAT_ARGB8888 (memory bytes B,G,R,A).
    pub fn readInto(self: *Gpu, out: []FrameBuf.Pixel) void {
        for (0..out.len) |i| {
            const r = self.readbuf[4 * i + 0];
            const g = self.readbuf[4 * i + 1];
            const b = self.readbuf[4 * i + 2];
            const a = self.readbuf[4 * i + 3];
            out[i] = [4]u8{ b, g, r, a };
        }
    }

    // Recreate the GBM surface + render target at a new size.
    pub fn resize(self: *Gpu, w: i32, h: i32) void {
        self.freeTargets();
        self.allocTargets(w, h);
        std.heap.page_allocator.free(self.readbuf);
        self.readbuf = std.heap.page_allocator.alloc(u8, @intCast(w * h * 4)) catch @panic("oom gpu readbuf");
        self.w = w;
        self.h = h;
    }

    pub fn deinit(self: *Gpu) void {
        self.freeTargets();
        _ = self.egl.MakeCurrent(self.dpy, EGL.NO_SURFACE, EGL.NO_SURFACE, null);
        if (self.egl_surface) |s| _ = self.egl.DestroySurface(self.dpy, s);
        if (self.gbm_surface) |s| self.gbm.surface_destroy(s);
        _ = self.egl.Terminate(self.dpy);
        _ = self.gbm.device_destroy(self.gbm_dev);
        _ = std.os.linux.close(self.drm_fd);
        std.heap.page_allocator.free(self.readbuf);
        self.lib_egl.close();
        self.lib_gl.close();
        self.lib_gbm.close();
    }

    // (Re)create the GBM bo + EGLImage + FBO render target at the given size.
    fn allocTargets(self: *Gpu, w: i32, h: i32) void {
        const gl = self.gl;
        self.gbm_bo = self.gbm.bo_create(self.gbm_dev, @intCast(w), @intCast(h), GBM.FORMAT_ARGB8888, GBM.BO_USE_RENDERING);
        if (self.gbm_bo == null) @panic("gbm_bo_create failed");
        const img_attribs = [_]EGL.int{ EGL.IMAGE_PRESERVED_KHR, @as(EGL.int, 1), EGL.NONE };
        const image = self.egl.CreateImageKHR(self.dpy, self.ctx, EGL.NATIVE_PIXMAP_KHR, self.gbm_bo, &img_attribs);
        if (image == EGL.NO_IMAGE_KHR) @panic("eglCreateImageKHR (gbm bo) failed");
        self.egl_image = image;
        gl.GenTextures(1, &self.tex);
        gl.BindTexture(GL.TEXTURE_2D, self.tex);
        gl.TexParameteri(GL.TEXTURE_2D, GL.TEXTURE_MIN_FILTER, GL.NEAREST);
        gl.TexParameteri(GL.TEXTURE_2D, GL.TEXTURE_MAG_FILTER, GL.NEAREST);
        self.egl.EGLImageTargetTexture2DOES(GL.TEXTURE_2D, image);
        gl.GenFramebuffers(1, &self.fbo);
        gl.BindFramebuffer(GL.FRAMEBUFFER, self.fbo);
        gl.FramebufferTexture2D(GL.FRAMEBUFFER, GL.COLOR_ATTACHMENT0, GL.TEXTURE_2D, self.tex, 0);
        if (gl.CheckFramebufferStatus(GL.FRAMEBUFFER) != GL.FRAMEBUFFER_COMPLETE)
            @panic("render-target framebuffer incomplete");
    }

    fn freeTargets(self: *Gpu) void {
        if (self.egl_image != EGL.NO_IMAGE_KHR) {
            _ = self.egl.DestroyImageKHR(self.dpy, self.egl_image);
            self.egl_image = EGL.NO_IMAGE_KHR;
        }
        if (self.fbo != 0) {
            self.gl.DeleteFramebuffers(1, &self.fbo);
            self.fbo = 0;
        }
        if (self.tex != 0) {
            self.gl.DeleteTextures(1, &self.tex);
            self.tex = 0;
        }
        if (self.gbm_bo) |bo| {
            self.gbm.bo_destroy(bo);
            self.gbm_bo = null;
        }
    }
};

fn openRenderNode() std.os.linux.fd_t {
    var pbuf: [64]u8 = undefined;
    for ([_][]const u8{ "/dev/dri/renderD128", "/dev/dri/renderD129" }) |p| {
        const pathz = std.fmt.bufPrintZ(&pbuf, "{s}", .{p}) catch continue;
        // O_RDWR | O_CLOEXEC (Linux x86_64)
        const flags: std.os.linux.O = @bitCast(@as(u32, 0x0002 | 0x80000)); // O_RDWR | O_CLOEXEC
        const fd = std.os.linux.open(pathz, flags, 0);
        if (fd >= 0) return @intCast(fd);
    }
    @panic("cannot open DRM render node (/dev/dri/renderD12[89]); need a GPU + KMS");
}

pub inline fn initial(Op: type, x: Op, args: anytype) bool {
    switch (Op) {
        way.wl_registry.Event.global => {
            args.reg_binder.bind(x, way.wl_compositor, args.wl_compositor.id);
            args.reg_binder.bind(x, xdg_shell.xdg_wm_base, args.xdg_wm_base.id);
            args.reg_binder.bind(x, way.wl_seat, args.wl_seat.id);
            args.reg_binder.bind(x, way.wl_shm, args.wl_shm.id);
        },
        way.wl_callback.Event.done => {
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
            if (@hasField(@TypeOf(args), "configured")) args.configured.* = true;
            return false;
        },
        way.wl_display.Event.Error => std.debug.print("Error: {f}\n", .{x.message}),
        else => std.debug.print("Ignored Msg {s}{}\n", .{ @typeName(Op), x }),
    }
    return true;
}

pub inline fn conf_input(Op: type, x: Op, args: anytype) bool {
    switch (Op) {
        way.wl_seat.Event.name => std.debug.print("Seat name: {f}\n", .{x.name}),
        way.wl_seat.Event.capabilities => {
            if (x.capabilities.keyboard) {
                args.con.io.sender.push(args.wl_seat, way.wl_seat.Request.get_keyboard{ .id = args.wl_keyboard });
            }
            if (x.capabilities.pointer) {
                args.con.io.sender.push(args.wl_seat, way.wl_seat.Request.get_pointer{ .id = args.wl_pointer });
            }
        },
        else => std.debug.print("Ignored message: {s}{}\n", .{ @typeName(Op), x }),
    }
    return true;
}

const State = struct {
    frame: u32 = 0,
    render: bool = true,
    busy: bool = true,
    gpu: *Gpu,
    fb: *FrameBuf,
    wl_surface: way.wl_surface,
    xdg_surface: xdg_shell.xdg_surface,
    xdg_wm_base: xdg_shell.xdg_wm_base,
    env: *clb.Env,
    con: *clb.Connection,
    size: [2]i32,
    pending: [2]i32,
    need_resize: bool = false,
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
            // Compositor is done with the in-flight buffer; allow the next frame.
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

    // Render + present one frame whenever the compositor is not holding a buffer.
    if (s.render and !s.busy) renderFrame(s);
    return true;
}

// Render the animated shader on the GPU, read it back, and present it to the
// compositor as a wl_shm-backed wl_buffer.
fn renderFrame(s: *State) void {
    s.frame += 1;
    if (s.frame % 60 == 0) std.debug.print("FRAME {d}\n", .{s.frame});
    const t = @as(f32, @floatFromInt(s.frame)) / 60.0;
    s.gpu.render(t);
    s.gpu.readInto(s.fb.pixels);
    s.con.io.sender.push(s.wl_surface, way.wl_surface.Request.attach{ .buffer = s.wl_buffer.id, .x = 0, .y = 0 });
    s.con.io.sender.push(s.wl_surface, way.wl_surface.Request.damage{ .x = 0, .y = 0, .width = std.math.maxInt(i32), .height = std.math.maxInt(i32) });
    s.con.io.sender.push(s.wl_surface, way.wl_surface.Request.commit{});
    s.con.send();
    s.busy = true;
    s.render = false;
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
    const xdg_wm_base = env.new(xdg_shell.xdg_wm_base);
    const wl_seat = env.new(way.wl_seat);
    const wl_shm = env.new(way.wl_shm);

    try clb.loop(init.io, &con, &env, .{
        .reg_binder = &reg_binder,
        .wl_compositor = wl_compositor,
        .xdg_wm_base = xdg_wm_base,
        .wl_seat = wl_seat,
        .wl_shm = wl_shm,
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
    const xdg_toplevel = env.new(xdg_shell.xdg_toplevel);
    std.Io.sleep(init.io, .fromMilliseconds(50), .real) catch {};
    con.io.sender.push(wl_compositor, way.wl_compositor.Request.create_surface{ .id = wl_surface });
    std.debug.print("CREATE wl_surface.id={} wl_compositor.id={} xdg_wm_base.id={} wl_seat.id={} wl_shm.id={}\n", .{ wl_surface.id, wl_compositor.id, xdg_wm_base.id, wl_seat.id, wl_shm.id });
    con.io.sender.push(xdg_wm_base, xdg_shell.xdg_wm_base.Request.get_xdg_surface{ .id = xdg_surface, .surface = wl_surface.id });
    con.io.sender.push(xdg_surface, xdg_shell.xdg_surface.Request.get_toplevel{ .id = xdg_toplevel });
    con.io.sender.push(wl_surface, way.wl_surface.Request.commit{});
    con.send();
    try std.Io.sleep(init.io, .fromMilliseconds(50), .real);

    try clb.loop(init.io, &con, &env, .{
        .con = &con,
        .xdg_surface = xdg_surface,
    }, .{configure}, clb.alwaysFalse);

    const MAX: [2]i32 = .{ 4096, 4096 };
    const INITIAL: [2]i32 = .{ 256, 256 };

    var fb = FrameBuf.init(MAX);
    fb.resize(INITIAL[0], INITIAL[1]);

    var gpu = try Gpu.init(INITIAL[0], INITIAL[1]);
    defer gpu.deinit();

    const wl_shm_pool = env.new(way.wl_shm_pool);
    const wl_buffer = env.new(way.wl_buffer);
    // A single memfd-backed pool sized to MAX; buffers are carved from it on
    // resize. Only the pool's fd crosses the socket once (columbus's sender
    // keeps the SCM_RIGHTS cmsg attached on later sends, which the compositor
    // tolerates by closing the extra fd).
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
    con.io.sender.push(wl_surface, way.wl_surface.Request.attach{ .buffer = wl_buffer.id, .x = 0, .y = 0 });
    con.io.sender.push(wl_surface, way.wl_surface.Request.damage{ .x = 0, .y = 0, .width = std.math.maxInt(i32), .height = std.math.maxInt(i32) });
    con.io.sender.push(wl_surface, way.wl_surface.Request.commit{});
    con.send();

    var state = State{
        .gpu = &gpu,
        .fb = &fb,
        .wl_surface = wl_surface,
        .xdg_surface = xdg_surface,
        .xdg_wm_base = xdg_wm_base,
        .env = &env,
        .con = &con,
        .size = INITIAL,
        .pending = INITIAL,
        .wl_shm_pool = wl_shm_pool,
        .wl_buffer = wl_buffer,
    };
    try clb.loop(init.io, &con, &env, &state, .{run}, clb.wait_for(.fromMilliseconds(16)));
}
// const xkb_keycode = keycode + 8;
