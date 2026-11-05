// Vulkan + Wayland example: draw a gradient with a Vulkan graphics pipeline
// directly into a GPU buffer, export that buffer as a Linux dma-buf, and hand
// the dma-buf to the compositor with zwp_linux_dmabuf_v1.
//
// Pixel data never touches the CPU: the shader writes into the VkDeviceMemory
// that is imported by the compositor through the dma-buf fd (zero-copy).
//
// Run it from the dev shell (`nix develop`), which provides libvulkan.so.1:
//     zig build run
const std = @import("std");
const clb = @import("columbus");
const way = clb.way.protocol.wayland;
const xdg_shell = clb.way.protocol.xdg_shell;
const linux = clb.way.protocol.linux_dmabuf_v1;
const types = clb.way.types;

const WIDTH: i32 = 800;
const HEIGHT: i32 = 600;

// DRM_FORMAT_ARGB8888 ('AR24'). On little-endian machines the bytes in memory
// are B, G, R, A, which is exactly VK_FORMAT_B8G8R8A8_UNORM.
const DRM_FORMAT_ARGB8888: u32 = 0x34325241;
// DRM_FORMAT_MOD_LINEAR: the image is created with VK_IMAGE_TILING_LINEAR, so
// the compositor can import it without any driver-specific tiling metadata.
const DRM_FORMAT_MOD_LINEAR: u64 = 0;

// SPIR-V for the fullscreen triangle (see tmp/shaders/gradient.* in the repo
// history): the fragment shader reads the push-constant resolution, writes the
// gradient and uses gl_FragCoord for the uv coordinates.
const vert_spv = [_]u32{
    0x07230203, 0x00010300, 0x0008000b, 0x0000002b, 0x00000000, 0x00020011, 0x00000001, 0x0006000b,
    0x00000001, 0x4c534c47, 0x6474732e, 0x3035342e, 0x00000000, 0x0003000e, 0x00000000, 0x00000001,
    0x0007000f, 0x00000000, 0x00000004, 0x6e69616d, 0x00000000, 0x0000000c, 0x0000001d, 0x00030003,
    0x00000002, 0x000001c2, 0x00040005, 0x00000004, 0x6e69616d, 0x00000000, 0x00030005, 0x00000009,
    0x00000070, 0x00060005, 0x0000000c, 0x565f6c67, 0x65747265, 0x646e4978, 0x00007865, 0x00060005,
    0x0000001b, 0x505f6c67, 0x65567265, 0x78657472, 0x00000000, 0x00060006, 0x0000001b, 0x00000000,
    0x505f6c67, 0x7469736f, 0x006e6f69, 0x00070006, 0x0000001b, 0x00000001, 0x505f6c67, 0x746e696f,
    0x657a6953, 0x00000000, 0x00070006, 0x0000001b, 0x00000002, 0x435f6c67, 0x4470696c, 0x61747369,
    0x0065636e, 0x00070006, 0x0000001b, 0x00000003, 0x435f6c67, 0x446c6c75, 0x61747369, 0x0065636e,
    0x00030005, 0x0000001d, 0x00000000, 0x00040047, 0x0000000c, 0x0000000b, 0x0000002a, 0x00030047,
    0x0000001b, 0x00000002, 0x00050048, 0x0000001b, 0x00000000, 0x0000000b, 0x00000000, 0x00050048,
    0x0000001b, 0x00000001, 0x0000000b, 0x00000001, 0x00050048, 0x0000001b, 0x00000002, 0x0000000b,
    0x00000003, 0x00050048, 0x0000001b, 0x00000003, 0x0000000b, 0x00000004, 0x00020013, 0x00000002,
    0x00030021, 0x00000003, 0x00000002, 0x00030016, 0x00000006, 0x00000020, 0x00040017, 0x00000007,
    0x00000006, 0x00000002, 0x00040020, 0x00000008, 0x00000007, 0x00000007, 0x00040015, 0x0000000a,
    0x00000020, 0x00000001, 0x00040020, 0x0000000b, 0x00000001, 0x0000000a, 0x0004003b, 0x0000000b,
    0x0000000c, 0x00000001, 0x0004002b, 0x0000000a, 0x0000000e, 0x00000001, 0x0004002b, 0x0000000a,
    0x00000010, 0x00000002, 0x00040017, 0x00000017, 0x00000006, 0x00000004, 0x00040015, 0x00000018,
    0x00000020, 0x00000000, 0x0004002b, 0x00000018, 0x00000019, 0x00000001, 0x0004001c, 0x0000001a,
    0x00000006, 0x00000019, 0x0006001e, 0x0000001b, 0x00000017, 0x00000006, 0x0000001a, 0x0000001a,
    0x00040020, 0x0000001c, 0x00000003, 0x0000001b, 0x0004003b, 0x0000001c, 0x0000001d, 0x00000003,
    0x0004002b, 0x0000000a, 0x0000001e, 0x00000000, 0x0004002b, 0x00000006, 0x00000020, 0x40000000,
    0x0004002b, 0x00000006, 0x00000022, 0x3f800000, 0x0004002b, 0x00000006, 0x00000025, 0x00000000,
    0x00040020, 0x00000029, 0x00000003, 0x00000017, 0x00050036, 0x00000002, 0x00000004, 0x00000000,
    0x00000003, 0x000200f8, 0x00000005, 0x0004003b, 0x00000008, 0x00000009, 0x00000007, 0x0004003d,
    0x0000000a, 0x0000000d, 0x0000000c, 0x000500c4, 0x0000000a, 0x0000000f, 0x0000000d, 0x0000000e,
    0x000500c7, 0x0000000a, 0x00000011, 0x0000000f, 0x00000010, 0x0004006f, 0x00000006, 0x00000012,
    0x00000011, 0x0004003d, 0x0000000a, 0x00000013, 0x0000000c, 0x000500c7, 0x0000000a, 0x00000014,
    0x00000013, 0x00000010, 0x0004006f, 0x00000006, 0x00000015, 0x00000014, 0x00050050, 0x00000007,
    0x00000016, 0x00000012, 0x00000015, 0x0003003e, 0x00000009, 0x00000016, 0x0004003d, 0x00000007,
    0x0000001f, 0x00000009, 0x0005008e, 0x00000007, 0x00000021, 0x0000001f, 0x00000020, 0x00050050,
    0x00000007, 0x00000023, 0x00000022, 0x00000022, 0x00050083, 0x00000007, 0x00000024, 0x00000021,
    0x00000023, 0x00050051, 0x00000006, 0x00000026, 0x00000024, 0x00000000, 0x00050051, 0x00000006,
    0x00000027, 0x00000024, 0x00000001, 0x00070050, 0x00000017, 0x00000028, 0x00000026, 0x00000027,
    0x00000025, 0x00000022, 0x00050041, 0x00000029, 0x0000002a, 0x0000001d, 0x0000001e, 0x0003003e,
    0x0000002a, 0x00000028, 0x000100fd, 0x00010038,
};
const frag_spv = [_]u32{
    0x07230203, 0x00010300, 0x0008000b, 0x00000046, 0x00000000, 0x00020011, 0x00000001, 0x0006000b,
    0x00000001, 0x4c534c47, 0x6474732e, 0x3035342e, 0x00000000, 0x0003000e, 0x00000000, 0x00000001,
    0x0007000f, 0x00000004, 0x00000004, 0x6e69616d, 0x00000000, 0x0000000c, 0x00000040, 0x00030010,
    0x00000004, 0x00000007, 0x00030003, 0x00000002, 0x000001c2, 0x00040005, 0x00000004, 0x6e69616d,
    0x00000000, 0x00030005, 0x00000009, 0x00007675, 0x00060005, 0x0000000c, 0x465f6c67, 0x43676172,
    0x64726f6f, 0x00000000, 0x00040005, 0x0000000f, 0x68737550, 0x00000000, 0x00060006, 0x0000000f,
    0x00000000, 0x6f736572, 0x6974756c, 0x00006e6f, 0x00040005, 0x00000011, 0x68737570, 0x00000000,
    0x00030005, 0x0000001a, 0x00706f74, 0x00040005, 0x0000001f, 0x74746f62, 0x00006d6f, 0x00040005,
    0x00000024, 0x6f6c6f63, 0x00000072, 0x00050005, 0x00000040, 0x5f74756f, 0x6f6c6f63, 0x00000072,
    0x00040047, 0x0000000c, 0x0000000b, 0x0000000f, 0x00030047, 0x0000000f, 0x00000002, 0x00050048,
    0x0000000f, 0x00000000, 0x00000023, 0x00000000, 0x00040047, 0x00000040, 0x0000001e, 0x00000000,
    0x00020013, 0x00000002, 0x00030021, 0x00000003, 0x00000002, 0x00030016, 0x00000006, 0x00000020,
    0x00040017, 0x00000007, 0x00000006, 0x00000002, 0x00040020, 0x00000008, 0x00000007, 0x00000007,
    0x00040017, 0x0000000a, 0x00000006, 0x00000004, 0x00040020, 0x0000000b, 0x00000001, 0x0000000a,
    0x0004003b, 0x0000000b, 0x0000000c, 0x00000001, 0x0003001e, 0x0000000f, 0x00000007, 0x00040020,
    0x00000010, 0x00000009, 0x0000000f, 0x0004003b, 0x00000010, 0x00000011, 0x00000009, 0x00040015,
    0x00000012, 0x00000020, 0x00000001, 0x0004002b, 0x00000012, 0x00000013, 0x00000000, 0x00040020,
    0x00000014, 0x00000009, 0x00000007, 0x00040017, 0x00000018, 0x00000006, 0x00000003, 0x00040020,
    0x00000019, 0x00000007, 0x00000018, 0x0004002b, 0x00000006, 0x0000001b, 0x3dcccccd, 0x0004002b,
    0x00000006, 0x0000001c, 0x3ea3d70a, 0x0004002b, 0x00000006, 0x0000001d, 0x3f3851ec, 0x0006002c,
    0x00000018, 0x0000001e, 0x0000001b, 0x0000001c, 0x0000001d, 0x0004002b, 0x00000006, 0x00000020,
    0x3f6b851f, 0x0004002b, 0x00000006, 0x00000021, 0x3ec28f5c, 0x0004002b, 0x00000006, 0x00000022,
    0x3e23d70a, 0x0006002c, 0x00000018, 0x00000023, 0x00000020, 0x00000021, 0x00000022, 0x00040015,
    0x00000027, 0x00000020, 0x00000000, 0x0004002b, 0x00000027, 0x00000028, 0x00000001, 0x00040020,
    0x00000029, 0x00000007, 0x00000006, 0x0004002b, 0x00000006, 0x0000002f, 0x3e4ccccd, 0x0004002b,
    0x00000006, 0x00000030, 0x3f59999a, 0x0004002b, 0x00000006, 0x00000031, 0x3f0ccccd, 0x0006002c,
    0x00000018, 0x00000032, 0x0000002f, 0x00000030, 0x00000031, 0x0004002b, 0x00000006, 0x00000033,
    0x3eb33333, 0x0004002b, 0x00000006, 0x00000034, 0x3f800000, 0x0004002b, 0x00000027, 0x00000035,
    0x00000000, 0x00040020, 0x0000003f, 0x00000003, 0x0000000a, 0x0004003b, 0x0000003f, 0x00000040,
    0x00000003, 0x00050036, 0x00000002, 0x00000004, 0x00000000, 0x00000003, 0x000200f8, 0x00000005,
    0x0004003b, 0x00000008, 0x00000009, 0x00000007, 0x0004003b, 0x00000019, 0x0000001a, 0x00000007,
    0x0004003b, 0x00000019, 0x0000001f, 0x00000007, 0x0004003b, 0x00000019, 0x00000024, 0x00000007,
    0x0004003d, 0x0000000a, 0x0000000d, 0x0000000c, 0x0007004f, 0x00000007, 0x0000000e, 0x0000000d,
    0x0000000d, 0x00000000, 0x00000001, 0x00050041, 0x00000014, 0x00000015, 0x00000011, 0x00000013,
    0x0004003d, 0x00000007, 0x00000016, 0x00000015, 0x00050088, 0x00000007, 0x00000017, 0x0000000e,
    0x00000016, 0x0003003e, 0x00000009, 0x00000017, 0x0003003e, 0x0000001a, 0x0000001e, 0x0003003e,
    0x0000001f, 0x00000023, 0x0004003d, 0x00000018, 0x00000025, 0x0000001f, 0x0004003d, 0x00000018,
    0x00000026, 0x0000001a, 0x00050041, 0x00000029, 0x0000002a, 0x00000009, 0x00000028, 0x0004003d,
    0x00000006, 0x0000002b, 0x0000002a, 0x00060050, 0x00000018, 0x0000002c, 0x0000002b, 0x0000002b,
    0x0000002b, 0x0008000c, 0x00000018, 0x0000002d, 0x00000001, 0x0000002e, 0x00000025, 0x00000026,
    0x0000002c, 0x0003003e, 0x00000024, 0x0000002d, 0x0004003d, 0x00000018, 0x0000002e, 0x00000024,
    0x00050041, 0x00000029, 0x00000036, 0x00000009, 0x00000035, 0x0004003d, 0x00000006, 0x00000037,
    0x00000036, 0x00050083, 0x00000006, 0x00000038, 0x00000034, 0x00000037, 0x00050085, 0x00000006,
    0x00000039, 0x00000033, 0x00000038, 0x00050041, 0x00000029, 0x0000003a, 0x00000009, 0x00000028,
    0x0004003d, 0x00000006, 0x0000003b, 0x0000003a, 0x00050085, 0x00000006, 0x0000003c, 0x00000039,
    0x0000003b, 0x00060050, 0x00000018, 0x0000003d, 0x0000003c, 0x0000003c, 0x0000003c, 0x0008000c,
    0x00000018, 0x0000003e, 0x00000001, 0x0000002e, 0x0000002e, 0x00000032, 0x0000003d, 0x0003003e,
    0x00000024, 0x0000003e, 0x0004003d, 0x00000018, 0x00000041, 0x00000024, 0x00050051, 0x00000006,
    0x00000042, 0x00000041, 0x00000000, 0x00050051, 0x00000006, 0x00000043, 0x00000041, 0x00000001,
    0x00050051, 0x00000006, 0x00000044, 0x00000041, 0x00000002, 0x00070050, 0x0000000a, 0x00000045,
    0x00000042, 0x00000043, 0x00000044, 0x00000034, 0x0003003e, 0x00000040, 0x00000045, 0x000100fd,
    0x00010038,
};

// Minimal hand-written Vulkan bindings. The libraries are loaded with dlopen so
// the example (like 4_egl_gl.zig) has no link-time dependency on libvulkan.
const Vk = struct {
    const Handle = ?*anyopaque;
    const Instance = Handle;
    const PhysicalDevice = Handle;
    const Device = Handle;
    const Queue = Handle;
    const CommandPool = Handle;
    const CommandBuffer = Handle;
    const Image = Handle;
    const ImageView = Handle;
    const DeviceMemory = Handle;
    const RenderPass = Handle;
    const Framebuffer = Handle;
    const ShaderModule = Handle;
    const PipelineLayout = Handle;
    const Pipeline = Handle;

    const Result = i32;
    const Bool32 = u32;
    const DeviceSize = u64;

    const SUCCESS: Result = 0;

    const STRUCTURE_TYPE_APPLICATION_INFO: u32 = 0;
    const STRUCTURE_TYPE_INSTANCE_CREATE_INFO: u32 = 1;
    const STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO: u32 = 2;
    const STRUCTURE_TYPE_DEVICE_CREATE_INFO: u32 = 3;
    const STRUCTURE_TYPE_SUBMIT_INFO: u32 = 4;
    const STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO: u32 = 5;
    const STRUCTURE_TYPE_IMAGE_CREATE_INFO: u32 = 14;
    const STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO: u32 = 15;
    const STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO: u32 = 16;
    const STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO: u32 = 18;
    const STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO: u32 = 19;
    const STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO: u32 = 20;
    const STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO: u32 = 22;
    const STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO: u32 = 23;
    const STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO: u32 = 24;
    const STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO: u32 = 26;
    const STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO: u32 = 28;
    const STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO: u32 = 30;
    const STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO: u32 = 37;
    const STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO: u32 = 38;
    const STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO: u32 = 39;
    const STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO: u32 = 40;
    const STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO: u32 = 42;
    const STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO: u32 = 43;
    const STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO: u32 = 1000127001;
    const STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO: u32 = 1000072001;
    const STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO: u32 = 1000072002;
    const STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR: u32 = 1000074002;

    const IMAGE_TYPE_2D: u32 = 1;
    const FORMAT_B8G8R8A8_UNORM: u32 = 44;
    const IMAGE_TILING_LINEAR: u32 = 1;
    const IMAGE_USAGE_COLOR_ATTACHMENT_BIT: u32 = 0x10;
    const SAMPLE_COUNT_1_BIT: u32 = 1;
    const SHARING_MODE_EXCLUSIVE: u32 = 0;
    const IMAGE_LAYOUT_UNDEFINED: u32 = 0;
    const IMAGE_LAYOUT_GENERAL: u32 = 1;
    const IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL: u32 = 2;
    const IMAGE_VIEW_TYPE_2D: u32 = 1;
    const COMPONENT_SWIZZLE_IDENTITY: u32 = 0;
    const IMAGE_ASPECT_COLOR_BIT: u32 = 1;
    const ATTACHMENT_LOAD_OP_DONT_CARE: u32 = 2;
    const ATTACHMENT_STORE_OP_STORE: u32 = 0;
    const PIPELINE_BIND_POINT_GRAPHICS: u32 = 0;
    const SHADER_STAGE_VERTEX_BIT: u32 = 0x1;
    const SHADER_STAGE_FRAGMENT_BIT: u32 = 0x10;
    const PRIMITIVE_TOPOLOGY_TRIANGLE_LIST: u32 = 3;
    const POLYGON_MODE_FILL: u32 = 0;
    const CULL_MODE_NONE: u32 = 0;
    const FRONT_FACE_COUNTER_CLOCKWISE: u32 = 0;
    const BLEND_FACTOR_ZERO: u32 = 0;
    const BLEND_OP_ADD: u32 = 0;
    const COLOR_COMPONENT_RGBA: u32 = 0xF;
    const QUEUE_GRAPHICS_BIT: u32 = 0x1;
    const MEMORY_PROPERTY_DEVICE_LOCAL_BIT: u32 = 0x1;
    const EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT: u32 = 0x200;
    const COMMAND_BUFFER_LEVEL_PRIMARY: u32 = 0;
    const SUBPASS_CONTENTS_INLINE: u32 = 0;

    const Extent2D = extern struct { width: u32 = 0, height: u32 = 0 };
    const Extent3D = extern struct { width: u32 = 0, height: u32 = 0, depth: u32 = 0 };
    const Offset2D = extern struct { x: i32 = 0, y: i32 = 0 };
    const Rect2D = extern struct { offset: Offset2D = .{}, extent: Extent2D = .{} };
    const Viewport = extern struct {
        x: f32 = 0,
        y: f32 = 0,
        width: f32 = 0,
        height: f32 = 0,
        minDepth: f32 = 0,
        maxDepth: f32 = 1,
    };

    const ApplicationInfo = extern struct {
        sType: u32 = STRUCTURE_TYPE_APPLICATION_INFO,
        pNext: ?*const anyopaque = null,
        pApplicationName: ?[*:0]const u8 = null,
        applicationVersion: u32 = 0,
        pEngineName: ?[*:0]const u8 = null,
        engineVersion: u32 = 0,
        apiVersion: u32 = 0,
    };
    const InstanceCreateInfo = extern struct {
        sType: u32 = STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        pNext: ?*const anyopaque = null,
        flags: u32 = 0,
        pApplicationInfo: ?*const ApplicationInfo = null,
        enabledLayerCount: u32 = 0,
        ppEnabledLayerNames: ?[*]const [*:0]const u8 = null,
        enabledExtensionCount: u32 = 0,
        ppEnabledExtensionNames: ?[*]const [*:0]const u8 = null,
    };
    const DeviceQueueCreateInfo = extern struct {
        sType: u32 = STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        pNext: ?*const anyopaque = null,
        flags: u32 = 0,
        queueFamilyIndex: u32 = 0,
        queueCount: u32 = 1,
        pQueuePriorities: *const f32 = undefined,
    };
    const DeviceCreateInfo = extern struct {
        sType: u32 = STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        pNext: ?*const anyopaque = null,
        flags: u32 = 0,
        queueCreateInfoCount: u32 = 0,
        pQueueCreateInfos: ?[*]const DeviceQueueCreateInfo = null,
        enabledLayerCount: u32 = 0,
        ppEnabledLayerNames: ?[*]const [*:0]const u8 = null,
        enabledExtensionCount: u32 = 0,
        ppEnabledExtensionNames: ?[*]const [*:0]const u8 = null,
        pEnabledFeatures: ?*const anyopaque = null,
    };
    const ExternalMemoryImageCreateInfo = extern struct {
        sType: u32 = STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
        pNext: ?*const anyopaque = null,
        handleTypes: u32 = EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT,
    };
    const ImageCreateInfo = extern struct {
        sType: u32 = STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        pNext: ?*const anyopaque = null,
        flags: u32 = 0,
        imageType: u32 = IMAGE_TYPE_2D,
        format: u32 = FORMAT_B8G8R8A8_UNORM,
        extent: Extent3D = .{},
        mipLevels: u32 = 1,
        arrayLayers: u32 = 1,
        samples: u32 = SAMPLE_COUNT_1_BIT,
        tiling: u32 = IMAGE_TILING_LINEAR,
        usage: u32 = IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        sharingMode: u32 = SHARING_MODE_EXCLUSIVE,
        queueFamilyIndexCount: u32 = 0,
        pQueueFamilyIndices: ?*const u32 = null,
        initialLayout: u32 = IMAGE_LAYOUT_UNDEFINED,
    };
    const MemoryRequirements = extern struct { size: DeviceSize, alignment: DeviceSize, memoryTypeBits: u32 };
    const MemoryType = extern struct { propertyFlags: u32, heapIndex: u32 };
    const MemoryHeap = extern struct { size: DeviceSize, flags: u32 };
    const MemoryProperties = extern struct {
        memoryTypeCount: u32,
        memoryTypes: [32]MemoryType,
        memoryHeapCount: u32,
        memoryHeaps: [16]MemoryHeap,
    };
    const MemoryDedicatedAllocateInfo = extern struct {
        sType: u32 = STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO,
        pNext: ?*const anyopaque = null,
        image: Image = null,
        buffer: Handle = null,
    };
    const ExportMemoryAllocateInfo = extern struct {
        sType: u32 = STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO,
        pNext: ?*const anyopaque = null,
        handleTypes: u32 = EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT,
    };
    const MemoryAllocateInfo = extern struct {
        sType: u32 = STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        pNext: ?*const anyopaque = null,
        allocationSize: DeviceSize = 0,
        memoryTypeIndex: u32 = 0,
    };
    const MemoryGetFdInfoKHR = extern struct {
        sType: u32 = STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR,
        pNext: ?*const anyopaque = null,
        memory: DeviceMemory = null,
        handleType: u32 = EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT,
    };
    const QueueFamilyProperties = extern struct {
        queueFlags: u32 = 0,
        queueCount: u32 = 0,
        timestampValidBits: u32 = 0,
        minImageTransferGranularity: Extent3D = .{},
    };
    const ExtensionProperties = extern struct { extensionName: [256]u8 = .{0} ** 256, specVersion: u32 = 0 };
    const ImageFormatProperties = extern struct {
        maxExtent: Extent3D = .{},
        maxMipLevels: u32 = 0,
        maxArrayLayers: u32 = 0,
        sampleCounts: u32 = 0,
        maxResourceSize: DeviceSize = 0,
    };
    const ComponentMapping = extern struct {
        r: u32 = COMPONENT_SWIZZLE_IDENTITY,
        g: u32 = COMPONENT_SWIZZLE_IDENTITY,
        b: u32 = COMPONENT_SWIZZLE_IDENTITY,
        a: u32 = COMPONENT_SWIZZLE_IDENTITY,
    };
    const ImageSubresourceRange = extern struct {
        aspectMask: u32 = IMAGE_ASPECT_COLOR_BIT,
        baseMipLevel: u32 = 0,
        levelCount: u32 = 1,
        baseArrayLayer: u32 = 0,
        layerCount: u32 = 1,
    };
    const ImageViewCreateInfo = extern struct {
        sType: u32 = STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        pNext: ?*const anyopaque = null,
        flags: u32 = 0,
        image: Image = null,
        viewType: u32 = IMAGE_VIEW_TYPE_2D,
        format: u32 = FORMAT_B8G8R8A8_UNORM,
        components: ComponentMapping = .{},
        subresourceRange: ImageSubresourceRange = .{},
    };
    const AttachmentDescription = extern struct {
        flags: u32 = 0,
        format: u32 = FORMAT_B8G8R8A8_UNORM,
        samples: u32 = SAMPLE_COUNT_1_BIT,
        loadOp: u32 = ATTACHMENT_LOAD_OP_DONT_CARE,
        storeOp: u32 = ATTACHMENT_STORE_OP_STORE,
        stencilLoadOp: u32 = ATTACHMENT_LOAD_OP_DONT_CARE,
        stencilStoreOp: u32 = ATTACHMENT_STORE_OP_STORE,
        initialLayout: u32 = IMAGE_LAYOUT_UNDEFINED,
        finalLayout: u32 = IMAGE_LAYOUT_GENERAL,
    };
    const AttachmentReference = extern struct {
        attachment: u32 = 0,
        layout: u32 = IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };
    const SubpassDescription = extern struct {
        flags: u32 = 0,
        pipelineBindPoint: u32 = PIPELINE_BIND_POINT_GRAPHICS,
        inputAttachmentCount: u32 = 0,
        pInputAttachments: ?[*]const AttachmentReference = null,
        colorAttachmentCount: u32 = 0,
        pColorAttachments: ?[*]const AttachmentReference = null,
        pResolveAttachments: ?[*]const AttachmentReference = null,
        pDepthStencilAttachment: ?*const AttachmentReference = null,
        preserveAttachmentCount: u32 = 0,
        pPreserveAttachments: ?[*]const u32 = null,
    };
    const RenderPassCreateInfo = extern struct {
        sType: u32 = STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        pNext: ?*const anyopaque = null,
        flags: u32 = 0,
        attachmentCount: u32 = 0,
        pAttachments: ?[*]const AttachmentDescription = null,
        subpassCount: u32 = 0,
        pSubpasses: ?[*]const SubpassDescription = null,
        dependencyCount: u32 = 0,
        pDependencies: ?*const anyopaque = null,
    };
    const FramebufferCreateInfo = extern struct {
        sType: u32 = STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
        pNext: ?*const anyopaque = null,
        flags: u32 = 0,
        renderPass: RenderPass = null,
        attachmentCount: u32 = 0,
        pAttachments: ?[*]const ImageView = null,
        width: u32 = 0,
        height: u32 = 0,
        layers: u32 = 1,
    };
    const ShaderModuleCreateInfo = extern struct {
        sType: u32 = STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        pNext: ?*const anyopaque = null,
        flags: u32 = 0,
        codeSize: usize = 0,
        pCode: ?[*]const u32 = null,
    };
    const PipelineShaderStageCreateInfo = extern struct {
        sType: u32 = STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        pNext: ?*const anyopaque = null,
        flags: u32 = 0,
        stage: u32 = 0,
        module: ShaderModule = null,
        pName: ?[*:0]const u8 = null,
        pSpecializationInfo: ?*const anyopaque = null,
    };
    const PipelineVertexInputStateCreateInfo = extern struct {
        sType: u32 = STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        pNext: ?*const anyopaque = null,
        flags: u32 = 0,
        vertexBindingDescriptionCount: u32 = 0,
        pVertexBindingDescriptions: ?*const anyopaque = null,
        vertexAttributeDescriptionCount: u32 = 0,
        pVertexAttributeDescriptions: ?*const anyopaque = null,
    };
    const PipelineInputAssemblyStateCreateInfo = extern struct {
        sType: u32 = STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        pNext: ?*const anyopaque = null,
        flags: u32 = 0,
        topology: u32 = PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        primitiveRestartEnable: u32 = 0,
    };
    const PipelineViewportStateCreateInfo = extern struct {
        sType: u32 = STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        pNext: ?*const anyopaque = null,
        flags: u32 = 0,
        viewportCount: u32 = 1,
        pViewports: ?[*]const Viewport = null,
        scissorCount: u32 = 1,
        pScissors: ?[*]const Rect2D = null,
    };
    const PipelineRasterizationStateCreateInfo = extern struct {
        sType: u32 = STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        pNext: ?*const anyopaque = null,
        flags: u32 = 0,
        depthClampEnable: u32 = 0,
        rasterizerDiscardEnable: u32 = 0,
        polygonMode: u32 = POLYGON_MODE_FILL,
        cullMode: u32 = CULL_MODE_NONE,
        frontFace: u32 = FRONT_FACE_COUNTER_CLOCKWISE,
        depthBiasEnable: u32 = 0,
        depthBiasConstantFactor: f32 = 0,
        depthBiasClamp: f32 = 0,
        depthBiasSlopeFactor: f32 = 0,
        lineWidth: f32 = 1,
    };
    const PipelineMultisampleStateCreateInfo = extern struct {
        sType: u32 = STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        pNext: ?*const anyopaque = null,
        flags: u32 = 0,
        rasterizationSamples: u32 = SAMPLE_COUNT_1_BIT,
        sampleShadingEnable: u32 = 0,
        minSampleShading: f32 = 0,
        pSampleMask: ?*const u32 = null,
        alphaToCoverageEnable: u32 = 0,
        alphaToOneEnable: u32 = 0,
    };
    const PipelineColorBlendAttachmentState = extern struct {
        blendEnable: u32 = 0,
        srcColorBlendFactor: u32 = BLEND_FACTOR_ZERO,
        dstColorBlendFactor: u32 = BLEND_FACTOR_ZERO,
        colorBlendOp: u32 = BLEND_OP_ADD,
        srcAlphaBlendFactor: u32 = BLEND_FACTOR_ZERO,
        dstAlphaBlendFactor: u32 = BLEND_FACTOR_ZERO,
        alphaBlendOp: u32 = BLEND_OP_ADD,
        colorWriteMask: u32 = COLOR_COMPONENT_RGBA,
    };
    const PipelineColorBlendStateCreateInfo = extern struct {
        sType: u32 = STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        pNext: ?*const anyopaque = null,
        flags: u32 = 0,
        logicOpEnable: u32 = 0,
        logicOp: u32 = 0,
        attachmentCount: u32 = 0,
        pAttachments: ?[*]const PipelineColorBlendAttachmentState = null,
        blendConstants: [4]f32 = .{ 0, 0, 0, 0 },
    };
    const PushConstantRange = extern struct { stageFlags: u32 = 0, offset: u32 = 0, size: u32 = 0 };
    const PipelineLayoutCreateInfo = extern struct {
        sType: u32 = STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        pNext: ?*const anyopaque = null,
        flags: u32 = 0,
        setLayoutCount: u32 = 0,
        pSetLayouts: ?*const anyopaque = null,
        pushConstantRangeCount: u32 = 0,
        pPushConstantRanges: ?[*]const PushConstantRange = null,
    };
    const GraphicsPipelineCreateInfo = extern struct {
        sType: u32 = STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        pNext: ?*const anyopaque = null,
        flags: u32 = 0,
        stageCount: u32 = 0,
        pStages: ?[*]const PipelineShaderStageCreateInfo = null,
        pVertexInputState: ?*const PipelineVertexInputStateCreateInfo = null,
        pInputAssemblyState: ?*const PipelineInputAssemblyStateCreateInfo = null,
        pTessellationState: ?*const anyopaque = null,
        pViewportState: ?*const PipelineViewportStateCreateInfo = null,
        pRasterizationState: ?*const PipelineRasterizationStateCreateInfo = null,
        pMultisampleState: ?*const PipelineMultisampleStateCreateInfo = null,
        pDepthStencilState: ?*const anyopaque = null,
        pColorBlendState: ?*const PipelineColorBlendStateCreateInfo = null,
        pDynamicState: ?*const anyopaque = null,
        layout: PipelineLayout = null,
        renderPass: RenderPass = null,
        subpass: u32 = 0,
        basePipelineHandle: Pipeline = null,
        basePipelineIndex: i32 = -1,
    };
    const CommandPoolCreateInfo = extern struct {
        sType: u32 = STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        pNext: ?*const anyopaque = null,
        flags: u32 = 0,
        queueFamilyIndex: u32 = 0,
    };
    const CommandBufferAllocateInfo = extern struct {
        sType: u32 = STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        pNext: ?*const anyopaque = null,
        commandPool: CommandPool = null,
        level: u32 = COMMAND_BUFFER_LEVEL_PRIMARY,
        commandBufferCount: u32 = 1,
    };
    const CommandBufferBeginInfo = extern struct {
        sType: u32 = STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        pNext: ?*const anyopaque = null,
        flags: u32 = 0,
        pInheritanceInfo: ?*const anyopaque = null,
    };
    const RenderPassBeginInfo = extern struct {
        sType: u32 = STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        pNext: ?*const anyopaque = null,
        renderPass: RenderPass = null,
        framebuffer: Framebuffer = null,
        renderArea: Rect2D = .{},
        clearValueCount: u32 = 0,
        pClearValues: ?*const anyopaque = null,
    };
    const SubmitInfo = extern struct {
        sType: u32 = STRUCTURE_TYPE_SUBMIT_INFO,
        pNext: ?*const anyopaque = null,
        waitSemaphoreCount: u32 = 0,
        pWaitSemaphores: ?*const anyopaque = null,
        pWaitDstStageMask: ?*const u32 = null,
        commandBufferCount: u32 = 0,
        pCommandBuffers: ?[*]const CommandBuffer = null,
        signalSemaphoreCount: u32 = 0,
        pSignalSemaphores: ?*const anyopaque = null,
    };

    const GetInstanceProcAddrFn = *const fn (Instance, [*:0]const u8) callconv(.c) ?*const anyopaque;
    const GetDeviceProcAddrFn = *const fn (Device, [*:0]const u8) callconv(.c) ?*const anyopaque;
    const CreateInstanceFn = *const fn (*const InstanceCreateInfo, ?*const anyopaque, *Instance) callconv(.c) Result;
    const DestroyInstanceFn = *const fn (Instance, ?*const anyopaque) callconv(.c) void;
    const EnumeratePhysicalDevicesFn = *const fn (Instance, *u32, ?[*]PhysicalDevice) callconv(.c) Result;
    const EnumerateDeviceExtensionPropertiesFn = *const fn (PhysicalDevice, ?[*:0]const u8, *u32, ?[*]ExtensionProperties) callconv(.c) Result;
    const GetPhysicalDeviceQueueFamilyPropertiesFn = *const fn (PhysicalDevice, *u32, ?[*]QueueFamilyProperties) callconv(.c) void;
    const GetPhysicalDeviceImageFormatPropertiesFn = *const fn (PhysicalDevice, u32, u32, u32, u32, u32, *ImageFormatProperties) callconv(.c) Result;
    const GetPhysicalDeviceMemoryPropertiesFn = *const fn (PhysicalDevice, *MemoryProperties) callconv(.c) void;
    const CreateDeviceFn = *const fn (PhysicalDevice, *const DeviceCreateInfo, ?*const anyopaque, *Device) callconv(.c) Result;
    const DestroyDeviceFn = *const fn (Device, ?*const anyopaque) callconv(.c) void;
    const GetDeviceQueueFn = *const fn (Device, u32, u32, *Queue) callconv(.c) void;
    const CreateImageFn = *const fn (Device, *const ImageCreateInfo, ?*const anyopaque, *Image) callconv(.c) Result;
    const DestroyImageFn = *const fn (Device, Image, ?*const anyopaque) callconv(.c) void;
    const GetImageMemoryRequirementsFn = *const fn (Device, Image, *MemoryRequirements) callconv(.c) void;
    const AllocateMemoryFn = *const fn (Device, *const MemoryAllocateInfo, ?*const anyopaque, *DeviceMemory) callconv(.c) Result;
    const FreeMemoryFn = *const fn (Device, DeviceMemory, ?*const anyopaque) callconv(.c) void;
    const BindImageMemoryFn = *const fn (Device, Image, DeviceMemory, DeviceSize) callconv(.c) Result;
    const GetMemoryFdKHRFn = *const fn (Device, *const MemoryGetFdInfoKHR, *i32) callconv(.c) Result;
    const ImageSubresource = extern struct { aspectMask: u32 = IMAGE_ASPECT_COLOR_BIT, mipLevel: u32 = 0, arrayLayer: u32 = 0 };
    const ImageSubresourceLayout = extern struct { offset: DeviceSize, size: DeviceSize, rowPitch: DeviceSize, arrayPitch: DeviceSize, depthPitch: DeviceSize };
    const GetImageSubresourceLayoutFn = *const fn (Device, Image, *const ImageSubresource, *ImageSubresourceLayout) callconv(.c) void;
    const CreateImageViewFn = *const fn (Device, *const ImageViewCreateInfo, ?*const anyopaque, *ImageView) callconv(.c) Result;
    const DestroyImageViewFn = *const fn (Device, ImageView, ?*const anyopaque) callconv(.c) void;
    const CreateRenderPassFn = *const fn (Device, *const RenderPassCreateInfo, ?*const anyopaque, *RenderPass) callconv(.c) Result;
    const DestroyRenderPassFn = *const fn (Device, RenderPass, ?*const anyopaque) callconv(.c) void;
    const CreateShaderModuleFn = *const fn (Device, *const ShaderModuleCreateInfo, ?*const anyopaque, *ShaderModule) callconv(.c) Result;
    const DestroyShaderModuleFn = *const fn (Device, ShaderModule, ?*const anyopaque) callconv(.c) void;
    const CreatePipelineLayoutFn = *const fn (Device, *const PipelineLayoutCreateInfo, ?*const anyopaque, *PipelineLayout) callconv(.c) Result;
    const DestroyPipelineLayoutFn = *const fn (Device, PipelineLayout, ?*const anyopaque) callconv(.c) void;
    const CreateGraphicsPipelinesFn = *const fn (Device, ?*const anyopaque, u32, *const GraphicsPipelineCreateInfo, ?*const anyopaque, ?[*]Pipeline) callconv(.c) Result;
    const DestroyPipelineFn = *const fn (Device, Pipeline, ?*const anyopaque) callconv(.c) void;
    const CreateFramebufferFn = *const fn (Device, *const FramebufferCreateInfo, ?*const anyopaque, *Framebuffer) callconv(.c) Result;
    const DestroyFramebufferFn = *const fn (Device, Framebuffer, ?*const anyopaque) callconv(.c) void;
    const CreateCommandPoolFn = *const fn (Device, *const CommandPoolCreateInfo, ?*const anyopaque, *CommandPool) callconv(.c) Result;
    const DestroyCommandPoolFn = *const fn (Device, CommandPool, ?*const anyopaque) callconv(.c) void;
    const AllocateCommandBuffersFn = *const fn (Device, *const CommandBufferAllocateInfo, *CommandBuffer) callconv(.c) Result;
    const BeginCommandBufferFn = *const fn (CommandBuffer, *const CommandBufferBeginInfo) callconv(.c) Result;
    const EndCommandBufferFn = *const fn (CommandBuffer) callconv(.c) Result;
    const CmdBeginRenderPassFn = *const fn (CommandBuffer, *const RenderPassBeginInfo, u32) callconv(.c) void;
    const CmdBindPipelineFn = *const fn (CommandBuffer, u32, Pipeline) callconv(.c) void;
    const CmdPushConstantsFn = *const fn (CommandBuffer, PipelineLayout, u32, u32, u32, ?*const anyopaque) callconv(.c) void;
    const CmdDrawFn = *const fn (CommandBuffer, u32, u32, u32, u32) callconv(.c) void;
    const CmdEndRenderPassFn = *const fn (CommandBuffer) callconv(.c) void;
    const QueueSubmitFn = *const fn (Queue, u32, *const SubmitInfo, ?*const anyopaque) callconv(.c) Result;
    const QueueWaitIdleFn = *const fn (Queue) callconv(.c) Result;
    const DeviceWaitIdleFn = *const fn (Device) callconv(.c) Result;

    gipa: GetInstanceProcAddrFn,
    gdpa: GetDeviceProcAddrFn = undefined,
    create_instance: CreateInstanceFn,
    destroy_instance: DestroyInstanceFn = undefined,
    enumerate_physical_devices: EnumeratePhysicalDevicesFn = undefined,
    enumerate_device_extension_properties: EnumerateDeviceExtensionPropertiesFn = undefined,
    get_physical_device_queue_family_properties: GetPhysicalDeviceQueueFamilyPropertiesFn = undefined,
    get_physical_device_image_format_properties: GetPhysicalDeviceImageFormatPropertiesFn = undefined,
    get_physical_device_memory_properties: GetPhysicalDeviceMemoryPropertiesFn = undefined,
    create_device: CreateDeviceFn = undefined,
    destroy_device: DestroyDeviceFn = undefined,
    get_device_queue: GetDeviceQueueFn = undefined,
    create_image: CreateImageFn = undefined,
    destroy_image: DestroyImageFn = undefined,
    get_image_memory_requirements: GetImageMemoryRequirementsFn = undefined,
    allocate_memory: AllocateMemoryFn = undefined,
    free_memory: FreeMemoryFn = undefined,
    bind_image_memory: BindImageMemoryFn = undefined,
    get_memory_fd_khr: GetMemoryFdKHRFn = undefined,
    get_image_subresource_layout: GetImageSubresourceLayoutFn = undefined,
    create_image_view: CreateImageViewFn = undefined,
    destroy_image_view: DestroyImageViewFn = undefined,
    create_render_pass: CreateRenderPassFn = undefined,
    destroy_render_pass: DestroyRenderPassFn = undefined,
    create_shader_module: CreateShaderModuleFn = undefined,
    destroy_shader_module: DestroyShaderModuleFn = undefined,
    create_pipeline_layout: CreatePipelineLayoutFn = undefined,
    destroy_pipeline_layout: DestroyPipelineLayoutFn = undefined,
    create_graphics_pipelines: CreateGraphicsPipelinesFn = undefined,
    destroy_pipeline: DestroyPipelineFn = undefined,
    create_framebuffer: CreateFramebufferFn = undefined,
    destroy_framebuffer: DestroyFramebufferFn = undefined,
    create_command_pool: CreateCommandPoolFn = undefined,
    destroy_command_pool: DestroyCommandPoolFn = undefined,
    allocate_command_buffers: AllocateCommandBuffersFn = undefined,
    begin_command_buffer: BeginCommandBufferFn = undefined,
    end_command_buffer: EndCommandBufferFn = undefined,
    cmd_begin_render_pass: CmdBeginRenderPassFn = undefined,
    cmd_bind_pipeline: CmdBindPipelineFn = undefined,
    cmd_push_constants: CmdPushConstantsFn = undefined,
    cmd_draw: CmdDrawFn = undefined,
    cmd_end_render_pass: CmdEndRenderPassFn = undefined,
    queue_submit: QueueSubmitFn = undefined,
    queue_wait_idle: QueueWaitIdleFn = undefined,
    device_wait_idle: DeviceWaitIdleFn = undefined,

    fn proc(comptime T: type, get_proc: anytype, handle: anytype, comptime name: [:0]const u8) T {
        return @ptrCast(get_proc(handle, name) orelse @panic("Vulkan function not found: " ++ name));
    }

    fn loadInstance(self: *Vk, instance: Instance) void {
        self.enumerate_physical_devices = proc(EnumeratePhysicalDevicesFn, self.gipa, instance, "vkEnumeratePhysicalDevices");
        self.enumerate_device_extension_properties = proc(EnumerateDeviceExtensionPropertiesFn, self.gipa, instance, "vkEnumerateDeviceExtensionProperties");
        self.get_physical_device_queue_family_properties = proc(GetPhysicalDeviceQueueFamilyPropertiesFn, self.gipa, instance, "vkGetPhysicalDeviceQueueFamilyProperties");
        self.get_physical_device_image_format_properties = proc(GetPhysicalDeviceImageFormatPropertiesFn, self.gipa, instance, "vkGetPhysicalDeviceImageFormatProperties");
        self.get_physical_device_memory_properties = proc(GetPhysicalDeviceMemoryPropertiesFn, self.gipa, instance, "vkGetPhysicalDeviceMemoryProperties");
        self.create_device = proc(CreateDeviceFn, self.gipa, instance, "vkCreateDevice");
        self.destroy_instance = proc(DestroyInstanceFn, self.gipa, instance, "vkDestroyInstance");
        self.gdpa = proc(GetDeviceProcAddrFn, self.gipa, instance, "vkGetDeviceProcAddr");
    }

    fn loadDevice(self: *Vk, device: Device) void {
        self.destroy_device = proc(DestroyDeviceFn, self.gdpa, device, "vkDestroyDevice");
        self.get_device_queue = proc(GetDeviceQueueFn, self.gdpa, device, "vkGetDeviceQueue");
        self.create_image = proc(CreateImageFn, self.gdpa, device, "vkCreateImage");
        self.destroy_image = proc(DestroyImageFn, self.gdpa, device, "vkDestroyImage");
        self.get_image_memory_requirements = proc(GetImageMemoryRequirementsFn, self.gdpa, device, "vkGetImageMemoryRequirements");
        self.allocate_memory = proc(AllocateMemoryFn, self.gdpa, device, "vkAllocateMemory");
        self.free_memory = proc(FreeMemoryFn, self.gdpa, device, "vkFreeMemory");
        self.bind_image_memory = proc(BindImageMemoryFn, self.gdpa, device, "vkBindImageMemory");
        self.get_memory_fd_khr = proc(GetMemoryFdKHRFn, self.gdpa, device, "vkGetMemoryFdKHR");
        self.get_image_subresource_layout = proc(GetImageSubresourceLayoutFn, self.gdpa, device, "vkGetImageSubresourceLayout");
        self.create_image_view = proc(CreateImageViewFn, self.gdpa, device, "vkCreateImageView");
        self.destroy_image_view = proc(DestroyImageViewFn, self.gdpa, device, "vkDestroyImageView");
        self.create_render_pass = proc(CreateRenderPassFn, self.gdpa, device, "vkCreateRenderPass");
        self.destroy_render_pass = proc(DestroyRenderPassFn, self.gdpa, device, "vkDestroyRenderPass");
        self.create_shader_module = proc(CreateShaderModuleFn, self.gdpa, device, "vkCreateShaderModule");
        self.destroy_shader_module = proc(DestroyShaderModuleFn, self.gdpa, device, "vkDestroyShaderModule");
        self.create_pipeline_layout = proc(CreatePipelineLayoutFn, self.gdpa, device, "vkCreatePipelineLayout");
        self.destroy_pipeline_layout = proc(DestroyPipelineLayoutFn, self.gdpa, device, "vkDestroyPipelineLayout");
        self.create_graphics_pipelines = proc(CreateGraphicsPipelinesFn, self.gdpa, device, "vkCreateGraphicsPipelines");
        self.destroy_pipeline = proc(DestroyPipelineFn, self.gdpa, device, "vkDestroyPipeline");
        self.create_framebuffer = proc(CreateFramebufferFn, self.gdpa, device, "vkCreateFramebuffer");
        self.destroy_framebuffer = proc(DestroyFramebufferFn, self.gdpa, device, "vkDestroyFramebuffer");
        self.create_command_pool = proc(CreateCommandPoolFn, self.gdpa, device, "vkCreateCommandPool");
        self.destroy_command_pool = proc(DestroyCommandPoolFn, self.gdpa, device, "vkDestroyCommandPool");
        self.allocate_command_buffers = proc(AllocateCommandBuffersFn, self.gdpa, device, "vkAllocateCommandBuffers");
        self.begin_command_buffer = proc(BeginCommandBufferFn, self.gdpa, device, "vkBeginCommandBuffer");
        self.end_command_buffer = proc(EndCommandBufferFn, self.gdpa, device, "vkEndCommandBuffer");
        self.cmd_begin_render_pass = proc(CmdBeginRenderPassFn, self.gdpa, device, "vkCmdBeginRenderPass");
        self.cmd_bind_pipeline = proc(CmdBindPipelineFn, self.gdpa, device, "vkCmdBindPipeline");
        self.cmd_push_constants = proc(CmdPushConstantsFn, self.gdpa, device, "vkCmdPushConstants");
        self.cmd_draw = proc(CmdDrawFn, self.gdpa, device, "vkCmdDraw");
        self.cmd_end_render_pass = proc(CmdEndRenderPassFn, self.gdpa, device, "vkCmdEndRenderPass");
        self.queue_submit = proc(QueueSubmitFn, self.gdpa, device, "vkQueueSubmit");
        self.queue_wait_idle = proc(QueueWaitIdleFn, self.gdpa, device, "vkQueueWaitIdle");
        self.device_wait_idle = proc(DeviceWaitIdleFn, self.gdpa, device, "vkDeviceWaitIdle");
    }
};

fn vkCheck(res: Vk.Result, what: []const u8) !void {
    if (res != Vk.SUCCESS) {
        std.debug.print("Vulkan: {s} failed ({})\n", .{ what, res });
        return error.VulkanFailed;
    }
}

const Gpu = struct {
    lib: std.DynLib,
    vk: Vk,
    instance: Vk.Instance,
    device: Vk.Device,
    queue: Vk.Queue,
    command_pool: Vk.CommandPool,
    command_buffer: Vk.CommandBuffer,
    render_pass: Vk.RenderPass,
    pipeline_layout: Vk.PipelineLayout,
    pipeline: Vk.Pipeline,
    vert_module: Vk.ShaderModule,
    frag_module: Vk.ShaderModule,
    framebuffer: Vk.Framebuffer,
    image_view: Vk.ImageView,
    image: Vk.Image,
    memory: Vk.DeviceMemory,
    extent: [2]u32,
    // dma-buf handle and linear layout of `image`, handed to the compositor.
    fd: i32,
    stride: u32,
    offset: u32,

    pub fn init(width: u32, height: u32) !Gpu {
        var lib = std.DynLib.open("libvulkan.so.1") catch {
            std.debug.print("Failed to load libvulkan.so.1 (run inside the nix dev shell: `nix develop`)\n", .{});
            return error.VulkanUnavailable;
        };
        errdefer lib.close();

        const gipa = lib.lookup(Vk.GetInstanceProcAddrFn, "vkGetInstanceProcAddr") orelse
            @panic("vkGetInstanceProcAddr not found in libvulkan");
        var vk = Vk{
            .gipa = gipa,
            .create_instance = @ptrCast(gipa(null, "vkCreateInstance") orelse @panic("vkCreateInstance not found")),
        };

        const app_info = Vk.ApplicationInfo{
            .pApplicationName = "columbus-vulkan",
            .pEngineName = "none",
            .apiVersion = 1 << 22, // Vulkan 1.0
        };
        const instance_info = Vk.InstanceCreateInfo{ .pApplicationInfo = &app_info };
        var instance: Vk.Instance = null;
        try vkCheck(vk.create_instance(&instance_info, null, &instance), "vkCreateInstance");
        vk.loadInstance(instance);

        // Pick a physical device that can render into a linear ARGB8888 image.
        var device_count: u32 = 0;
        try vkCheck(vk.enumerate_physical_devices(instance, &device_count, null), "vkEnumeratePhysicalDevices");
        var physicals: [8]Vk.PhysicalDevice = undefined;
        device_count = @min(device_count, physicals.len);
        try vkCheck(vk.enumerate_physical_devices(instance, &device_count, &physicals), "vkEnumeratePhysicalDevices");

        var physical: Vk.PhysicalDevice = null;
        var queue_family: u32 = 0;
        for (physicals[0..device_count]) |candidate| {
            var format_props: Vk.ImageFormatProperties = undefined;
            const format_ok = vk.get_physical_device_image_format_properties(
                candidate,
                Vk.FORMAT_B8G8R8A8_UNORM,
                Vk.IMAGE_TYPE_2D,
                Vk.IMAGE_TILING_LINEAR,
                Vk.IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
                0,
                &format_props,
            ) == Vk.SUCCESS;

            var families: [16]Vk.QueueFamilyProperties = undefined;
            var family_count: u32 = families.len;
            vk.get_physical_device_queue_family_properties(candidate, &family_count, &families);
            var graphics: ?u32 = null;
            for (families[0..family_count], 0..) |f, i| {
                if (f.queueFlags & Vk.QUEUE_GRAPHICS_BIT != 0) {
                    graphics = @intCast(i);
                    break;
                }
            }
            if (format_ok and graphics != null) {
                physical = candidate;
                queue_family = graphics.?;
                break;
            }
        }
        if (physical == null) @panic("no Vulkan device supports linear B8G8R8A8 color attachment");

        const required_exts = [_][*:0]const u8{
            "VK_KHR_external_memory",
            "VK_KHR_external_memory_fd",
            "VK_EXT_external_memory_dma_buf",
        };
        try checkDeviceExtensions(vk, physical, &required_exts);

        const priority: f32 = 1;
        const queue_info = Vk.DeviceQueueCreateInfo{ .queueFamilyIndex = queue_family, .pQueuePriorities = &priority };
        const device_info = Vk.DeviceCreateInfo{
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = @ptrCast(&queue_info),
            .enabledExtensionCount = required_exts.len,
            .ppEnabledExtensionNames = &required_exts,
        };
        var device: Vk.Device = null;
        try vkCheck(vk.create_device(physical, &device_info, null, &device), "vkCreateDevice");
        vk.loadDevice(device);

        var queue: Vk.Queue = null;
        vk.get_device_queue(device, queue_family, 0, &queue);

        // Render target: a linear B8G8R8A8 image whose memory can be exported as
        // a dma-buf. The render pass below writes the gradient into it.
        const external_info = Vk.ExternalMemoryImageCreateInfo{};
        const image_info = Vk.ImageCreateInfo{
            .pNext = @ptrCast(&external_info),
            .extent = .{ .width = width, .height = height, .depth = 1 },
        };
        var image: Vk.Image = null;
        try vkCheck(vk.create_image(device, &image_info, null, &image), "vkCreateImage");

        var requirements: Vk.MemoryRequirements = undefined;
        vk.get_image_memory_requirements(device, image, &requirements);

        var memory_props: Vk.MemoryProperties = undefined;
        vk.get_physical_device_memory_properties(physical, &memory_props);
        var memory_type: ?u32 = null;
        for (memory_props.memoryTypes[0..memory_props.memoryTypeCount], 0..) |t, i| {
            if (requirements.memoryTypeBits & (@as(u32, 1) << @intCast(i)) == 0) continue;
            if (t.propertyFlags & Vk.MEMORY_PROPERTY_DEVICE_LOCAL_BIT != 0) {
                memory_type = @intCast(i);
                break;
            }
        }
        const memory_type_index = memory_type orelse @panic("no device-local memory type for dma-buf image");

        const dedicated = Vk.MemoryDedicatedAllocateInfo{ .image = image };
        const export_info = Vk.ExportMemoryAllocateInfo{ .pNext = @ptrCast(&dedicated) };
        const alloc_info = Vk.MemoryAllocateInfo{
            .pNext = @ptrCast(&export_info),
            .allocationSize = requirements.size,
            .memoryTypeIndex = memory_type_index,
        };
        var memory: Vk.DeviceMemory = null;
        try vkCheck(vk.allocate_memory(device, &alloc_info, null, &memory), "vkAllocateMemory");
        try vkCheck(vk.bind_image_memory(device, image, memory, 0), "vkBindImageMemory");

        var fd: i32 = -1;
        const fd_info = Vk.MemoryGetFdInfoKHR{ .memory = memory };
        try vkCheck(vk.get_memory_fd_khr(device, &fd_info, &fd), "vkGetMemoryFdKHR");

        var layout: Vk.ImageSubresourceLayout = undefined;
        vk.get_image_subresource_layout(device, image, &.{}, &layout);

        const image_view_info = Vk.ImageViewCreateInfo{ .image = image };
        var image_view: Vk.ImageView = null;
        try vkCheck(vk.create_image_view(device, &image_view_info, null, &image_view), "vkCreateImageView");

        const color_ref = Vk.AttachmentReference{};
        const subpass = Vk.SubpassDescription{
            .colorAttachmentCount = 1,
            .pColorAttachments = @ptrCast(&color_ref),
        };
        const attachment = Vk.AttachmentDescription{};
        const render_pass_info = Vk.RenderPassCreateInfo{
            .attachmentCount = 1,
            .pAttachments = @ptrCast(&attachment),
            .subpassCount = 1,
            .pSubpasses = @ptrCast(&subpass),
        };
        var render_pass: Vk.RenderPass = null;
        try vkCheck(vk.create_render_pass(device, &render_pass_info, null, &render_pass), "vkCreateRenderPass");

        const framebuffer_info = Vk.FramebufferCreateInfo{
            .renderPass = render_pass,
            .attachmentCount = 1,
            .pAttachments = @ptrCast(&image_view),
            .width = width,
            .height = height,
        };
        var framebuffer: Vk.Framebuffer = null;
        try vkCheck(vk.create_framebuffer(device, &framebuffer_info, null, &framebuffer), "vkCreateFramebuffer");

        const vert_module = try createShaderModule(vk, device, &vert_spv);
        const frag_module = try createShaderModule(vk, device, &frag_spv);

        const push_range = Vk.PushConstantRange{
            .stageFlags = Vk.SHADER_STAGE_FRAGMENT_BIT,
            .size = @sizeOf([2]f32),
        };
        const pipeline_layout_info = Vk.PipelineLayoutCreateInfo{
            .pushConstantRangeCount = 1,
            .pPushConstantRanges = @ptrCast(&push_range),
        };
        var pipeline_layout: Vk.PipelineLayout = null;
        try vkCheck(vk.create_pipeline_layout(device, &pipeline_layout_info, null, &pipeline_layout), "vkCreatePipelineLayout");

        const stages = [_]Vk.PipelineShaderStageCreateInfo{
            .{ .stage = Vk.SHADER_STAGE_VERTEX_BIT, .module = vert_module, .pName = "main" },
            .{ .stage = Vk.SHADER_STAGE_FRAGMENT_BIT, .module = frag_module, .pName = "main" },
        };
        const vertex_input = Vk.PipelineVertexInputStateCreateInfo{};
        const input_assembly = Vk.PipelineInputAssemblyStateCreateInfo{};
        const viewport = Vk.Viewport{ .width = @floatFromInt(width), .height = @floatFromInt(height) };
        const scissor = Vk.Rect2D{ .extent = .{ .width = width, .height = height } };
        const viewport_state = Vk.PipelineViewportStateCreateInfo{
            .pViewports = @ptrCast(&viewport),
            .pScissors = @ptrCast(&scissor),
        };
        const rasterization = Vk.PipelineRasterizationStateCreateInfo{};
        const multisample = Vk.PipelineMultisampleStateCreateInfo{};
        const blend_attachment = Vk.PipelineColorBlendAttachmentState{};
        const color_blend = Vk.PipelineColorBlendStateCreateInfo{
            .attachmentCount = 1,
            .pAttachments = @ptrCast(&blend_attachment),
        };
        const pipeline_info = Vk.GraphicsPipelineCreateInfo{
            .stageCount = stages.len,
            .pStages = &stages,
            .pVertexInputState = &vertex_input,
            .pInputAssemblyState = &input_assembly,
            .pViewportState = &viewport_state,
            .pRasterizationState = &rasterization,
            .pMultisampleState = &multisample,
            .pColorBlendState = &color_blend,
            .layout = pipeline_layout,
            .renderPass = render_pass,
        };
        var pipeline: Vk.Pipeline = null;
        try vkCheck(vk.create_graphics_pipelines(device, null, 1, &pipeline_info, null, @ptrCast(&pipeline)), "vkCreateGraphicsPipelines");

        const pool_info = Vk.CommandPoolCreateInfo{ .queueFamilyIndex = queue_family };
        var command_pool: Vk.CommandPool = null;
        try vkCheck(vk.create_command_pool(device, &pool_info, null, &command_pool), "vkCreateCommandPool");

        const alloc_buffers_info = Vk.CommandBufferAllocateInfo{ .commandPool = command_pool };
        var command_buffer: Vk.CommandBuffer = null;
        try vkCheck(vk.allocate_command_buffers(device, &alloc_buffers_info, &command_buffer), "vkAllocateCommandBuffers");

        const begin_info = Vk.CommandBufferBeginInfo{};
        try vkCheck(vk.begin_command_buffer(command_buffer, &begin_info), "vkBeginCommandBuffer");
        const render_area = Vk.Rect2D{ .extent = .{ .width = width, .height = height } };
        const pass_begin = Vk.RenderPassBeginInfo{
            .renderPass = render_pass,
            .framebuffer = framebuffer,
            .renderArea = render_area,
        };
        vk.cmd_begin_render_pass(command_buffer, &pass_begin, Vk.SUBPASS_CONTENTS_INLINE);
        vk.cmd_bind_pipeline(command_buffer, Vk.PIPELINE_BIND_POINT_GRAPHICS, pipeline);
        const resolution = [2]f32{ @floatFromInt(width), @floatFromInt(height) };
        vk.cmd_push_constants(command_buffer, pipeline_layout, Vk.SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(@TypeOf(resolution)), &resolution);
        vk.cmd_draw(command_buffer, 3, 1, 0, 0);
        vk.cmd_end_render_pass(command_buffer);
        try vkCheck(vk.end_command_buffer(command_buffer), "vkEndCommandBuffer");

        return .{
            .lib = lib,
            .vk = vk,
            .instance = instance,
            .device = device,
            .queue = queue,
            .command_pool = command_pool,
            .command_buffer = command_buffer,
            .render_pass = render_pass,
            .pipeline_layout = pipeline_layout,
            .pipeline = pipeline,
            .vert_module = vert_module,
            .frag_module = frag_module,
            .framebuffer = framebuffer,
            .image_view = image_view,
            .image = image,
            .memory = memory,
            .extent = .{ width, height },
            .fd = fd,
            .stride = @intCast(layout.rowPitch),
            .offset = @intCast(layout.offset),
        };
    }

    /// Executes the recorded draw. Waits for the GPU so the dma-buf is complete
    /// before the compositor is allowed to sample it.
    pub fn render(self: *Gpu) !void {
        var cmd = [_]Vk.CommandBuffer{self.command_buffer};
        const submit = Vk.SubmitInfo{
            .commandBufferCount = 1,
            .pCommandBuffers = &cmd,
        };
        try vkCheck(self.vk.queue_submit(self.queue, 1, &submit, null), "vkQueueSubmit");
        try vkCheck(self.vk.queue_wait_idle(self.queue), "vkQueueWaitIdle");
    }

    pub fn deinit(self: *Gpu) void {
        const vk = self.vk;
        _ = vk.device_wait_idle(self.device);
        vk.destroy_pipeline(self.device, self.pipeline, null);
        vk.destroy_pipeline_layout(self.device, self.pipeline_layout, null);
        vk.destroy_framebuffer(self.device, self.framebuffer, null);
        vk.destroy_render_pass(self.device, self.render_pass, null);
        vk.destroy_image_view(self.device, self.image_view, null);
        vk.destroy_shader_module(self.device, self.vert_module, null);
        vk.destroy_shader_module(self.device, self.frag_module, null);
        vk.destroy_command_pool(self.device, self.command_pool, null);
        vk.destroy_image(self.device, self.image, null);
        vk.free_memory(self.device, self.memory, null);
        vk.destroy_device(self.device, null);
        vk.destroy_instance(self.instance, null);
        _ = std.os.linux.close(self.fd);
        self.lib.close();
    }
};

fn createShaderModule(vk: Vk, device: Vk.Device, code: []const u32) !Vk.ShaderModule {
    const info = Vk.ShaderModuleCreateInfo{
        .codeSize = code.len * @sizeOf(u32),
        .pCode = code.ptr,
    };
    var module: Vk.ShaderModule = null;
    try vkCheck(vk.create_shader_module(device, &info, null, &module), "vkCreateShaderModule");
    return module;
}

fn checkDeviceExtensions(vk: Vk, physical: Vk.PhysicalDevice, required: []const [*:0]const u8) !void {
    var count: u32 = 0;
    _ = vk.enumerate_device_extension_properties(physical, null, &count, null);
    var props: [128]Vk.ExtensionProperties = undefined;
    count = @min(count, props.len);
    _ = vk.enumerate_device_extension_properties(physical, null, &count, &props);

    for (required) |name| {
        const wanted = std.mem.span(name);
        for (props[0..count]) |p| {
            if (std.mem.eql(u8, std.mem.sliceTo(&p.extensionName, 0), wanted)) break;
        } else {
            std.debug.print("Vulkan device extension missing: {s}\n", .{wanted});
            return error.VulkanExtensionMissing;
        }
    }
}

// A single dmabuf-backed Vulkan image is presented. It is never resized, so
// the window is fixed to the image size.
const State = struct {
    con: *clb.Connection,
    env: *clb.Env,
    wl_surface: way.wl_surface,
    xdg_surface: xdg_shell.xdg_surface,
    xdg_wm_base: xdg_shell.xdg_wm_base,
    wl_buffer: way.wl_buffer,
};

fn initial(Op: type, x: Op, args: anytype) bool {
    switch (Op) {
        way.wl_registry.Event.global => {
            args.reg_binder.bind(x, way.wl_compositor, args.wl_compositor.id);
            args.reg_binder.bind(x, xdg_shell.xdg_wm_base, args.xdg_wm_base.id);
            // RegistryBinder always binds the client-side maximum version; clamp
            // to what the compositor actually advertises.
            if (x.interface.eql("zwp_linux_dmabuf_v1")) {
                args.con.io.sender.push(args.reg_binder.registry, way.wl_registry.Request.bind{
                    .name = x.name,
                    .id = .{
                        .interface = types.str.fromStr("zwp_linux_dmabuf_v1"),
                        .version = @min(x.version, linux.zwp_linux_dmabuf_v1.Version),
                        .id = args.dmabuf.id,
                    },
                });
                args.con.send();
            }
        },
        way.wl_callback.Event.done => return false,
        way.wl_display.Event.delete_id => args.env.delete(x.id),
        way.wl_display.Event.Error => std.debug.print("Error: {f}\n", .{x.message}),
        else => std.debug.print("Ignored Msg {s}{}\n", .{ @typeName(Op), x }),
    }
    return true;
}

fn configure(Op: type, x: Op, args: anytype) bool {
    switch (Op) {
        xdg_shell.xdg_surface.Event.configure => {
            args.con.io.sender.push(args.xdg_surface, xdg_shell.xdg_surface.Request.ack_configure{ .serial = x.serial });
            args.con.send();
            return false;
        },
        xdg_shell.xdg_toplevel.Event.configure => {},
        way.wl_display.Event.delete_id => args.env.delete(x.id),
        way.wl_display.Event.Error => std.debug.print("Error: {f}\n", .{x.message}),
        else => std.debug.print("Ignored Msg {s}{}\n", .{ @typeName(Op), x }),
    }
    return true;
}

fn run(Op: type, x: Op, s: *State) bool {
    switch (Op) {
        xdg_shell.xdg_surface.Event.configure => {
            s.con.io.sender.push(s.xdg_surface, xdg_shell.xdg_surface.Request.ack_configure{ .serial = x.serial });
            s.con.send();
        },
        xdg_shell.xdg_toplevel.Event.configure => {},
        xdg_shell.xdg_toplevel.Event.close => {
            std.debug.print("Closing window!\n", .{});
            return false;
        },
        xdg_shell.xdg_wm_base.Event.ping => {
            s.con.io.sender.push(s.xdg_wm_base, xdg_shell.xdg_wm_base.Request.pong{ .serial = x.serial });
            s.con.send();
        },
        linux.zwp_linux_buffer_params_v1.Event.failed => {
            std.debug.print("Compositor rejected the dma-buf\n", .{});
            return false;
        },
        way.wl_display.Event.delete_id => s.env.delete(x.id),
        way.wl_display.Event.Error => std.debug.print("Error: {f}\n", .{x.message}),
        way.wl_buffer.Event.release => {},
        else => std.debug.print("Ignored Msg {s}{}\n", .{ @typeName(Op), x }),
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
    const xdg_wm_base = env.new(xdg_shell.xdg_wm_base);
    const dmabuf = env.new(linux.zwp_linux_dmabuf_v1);
    try clb.loop(init.io, &con, &env, .{
        .reg_binder = &reg_binder,
        .wl_compositor = wl_compositor,
        .xdg_wm_base = xdg_wm_base,
        .dmabuf = dmabuf,
        .con = &con,
        .env = &env,
    }, .{initial}, clb.wait_for(.fromMilliseconds(16)));

    const wl_surface = env.new(way.wl_surface);
    const xdg_surface = env.new(xdg_shell.xdg_surface);
    const xdg_toplevel = env.new(xdg_shell.xdg_toplevel);
    con.io.sender.push(wl_compositor, way.wl_compositor.Request.create_surface{ .id = wl_surface });
    con.io.sender.push(xdg_wm_base, xdg_shell.xdg_wm_base.Request.get_xdg_surface{ .id = xdg_surface, .surface = wl_surface.id });
    con.io.sender.push(xdg_surface, xdg_shell.xdg_surface.Request.get_toplevel{ .id = xdg_toplevel });
    con.io.sender.push(xdg_toplevel, xdg_shell.xdg_toplevel.Request.set_title{ .title = types.str.fromStr("columbus vulkan gradient") });
    con.io.sender.push(xdg_toplevel, xdg_shell.xdg_toplevel.Request.set_app_id{ .app_id = types.str.fromStr("columbus-vulkan") });
    con.io.sender.push(xdg_toplevel, xdg_shell.xdg_toplevel.Request.set_min_size{ .width = WIDTH, .height = HEIGHT });
    con.io.sender.push(xdg_toplevel, xdg_shell.xdg_toplevel.Request.set_max_size{ .width = WIDTH, .height = HEIGHT });
    con.io.sender.push(wl_surface, way.wl_surface.Request.commit{});
    con.send();
    try std.Io.sleep(init.io, .fromMilliseconds(50), .real); // too fast otherwise

    try clb.loop(init.io, &con, &env, .{
        .con = &con,
        .env = &env,
        .xdg_surface = xdg_surface,
    }, .{configure}, clb.wait_for(.fromMilliseconds(16)));

    // Render once on the GPU. `fd` refers to the same memory the shader wrote.
    var gpu = try Gpu.init(@intCast(WIDTH), @intCast(HEIGHT));
    defer gpu.deinit();
    try gpu.render();

    // Import the dma-buf into Wayland and wrap it in a wl_buffer.
    const params = env.new(linux.zwp_linux_buffer_params_v1);
    const wl_buffer = env.new(way.wl_buffer);
    con.io.sender.push(dmabuf, linux.zwp_linux_dmabuf_v1.Request.create_params{ .params_id = params });
    con.io.sender.push(params, linux.zwp_linux_buffer_params_v1.Request.add{
        .fd = .{ .fd = gpu.fd },
        .plane_idx = 0,
        .offset = gpu.offset,
        .stride = gpu.stride,
        .modifier_hi = @intCast(DRM_FORMAT_MOD_LINEAR >> 32),
        .modifier_lo = @truncate(DRM_FORMAT_MOD_LINEAR),
    });
    con.io.sender.push(params, linux.zwp_linux_buffer_params_v1.Request.create_immed{
        .buffer_id = wl_buffer,
        .width = WIDTH,
        .height = HEIGHT,
        .format = DRM_FORMAT_ARGB8888,
        .flags = .{},
    });
    con.io.sender.push(params, linux.zwp_linux_buffer_params_v1.Request.destroy{});
    con.send();
    // columbus keeps the compressed cmsg around after send(); clear its length
    // so the dma-buf fd isn't attached to (and duplicated by) every later
    // message. This is the only place an fd is sent.
    con.io.sender.ctrl_len = 0;

    con.io.sender.push(wl_surface, way.wl_surface.Request.attach{ .buffer = wl_buffer.id, .x = 0, .y = 0 });
    con.io.sender.push(wl_surface, way.wl_surface.Request.damage{ .x = 0, .y = 0, .width = std.math.maxInt(i32), .height = std.math.maxInt(i32) });
    con.io.sender.push(wl_surface, way.wl_surface.Request.commit{});
    con.send();

    var state = State{
        .con = &con,
        .env = &env,
        .wl_surface = wl_surface,
        .xdg_surface = xdg_surface,
        .xdg_wm_base = xdg_wm_base,
        .wl_buffer = wl_buffer,
    };
    try clb.loop(init.io, &con, &env, &state, .{run}, clb.wait_for(.fromMilliseconds(16)));
}
