// Vulkan + Wayland example: draw a gradient with a Vulkan graphics pipeline
// directly into a GPU buffer, export that buffer as a Linux dma-buf, and hand
// the dma-buf to the compositor with zwp_linux_dmabuf_v1.
//
// Pixel data never touches the CPU: the shader writes into the VkDeviceMemory
// that is imported by the compositor through the dma-buf fd (zero-copy).
//
// Run it from the dev shell (`nix develop`), which provides libvulkan.so.1 and
// puts the Vulkan headers on the include path (`<vulkan/vulkan.h>`):
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
const vert_spv = [_]u32{ 0x07230203, 0x00010300, 0x0008000b, 0x0000002b, 0x00000000, 0x00020011, 0x00000001, 0x0006000b, 0x00000001, 0x4c534c47, 0x6474732e, 0x3035342e, 0x00000000, 0x0003000e, 0x00000000, 0x00000001, 0x0007000f, 0x00000000, 0x00000004, 0x6e69616d, 0x00000000, 0x0000000c, 0x0000001d, 0x00030003, 0x00000002, 0x000001c2, 0x00040005, 0x00000004, 0x6e69616d, 0x00000000, 0x00030005, 0x00000009, 0x00000070, 0x00060005, 0x0000000c, 0x565f6c67, 0x65747265, 0x646e4978, 0x00007865, 0x00060005, 0x0000001b, 0x505f6c67, 0x65567265, 0x78657472, 0x00000000, 0x00060006, 0x0000001b, 0x00000000, 0x505f6c67, 0x7469736f, 0x006e6f69, 0x00070006, 0x0000001b, 0x00000001, 0x505f6c67, 0x746e696f, 0x657a6953, 0x00000000, 0x00070006, 0x0000001b, 0x00000002, 0x435f6c67, 0x4470696c, 0x61747369, 0x0065636e, 0x00070006, 0x0000001b, 0x00000003, 0x435f6c67, 0x446c6c75, 0x61747369, 0x0065636e, 0x00030005, 0x0000001d, 0x00000000, 0x00040047, 0x0000000c, 0x0000000b, 0x0000002a, 0x00030047, 0x0000001b, 0x00000002, 0x00050048, 0x0000001b, 0x00000000, 0x0000000b, 0x00000000, 0x00050048, 0x0000001b, 0x00000001, 0x0000000b, 0x00000001, 0x00050048, 0x0000001b, 0x00000002, 0x0000000b, 0x00000003, 0x00050048, 0x0000001b, 0x00000003, 0x0000000b, 0x00000004, 0x00020013, 0x00000002, 0x00030021, 0x00000003, 0x00000002, 0x00030016, 0x00000006, 0x00000020, 0x00040017, 0x00000007, 0x00000006, 0x00000002, 0x00040020, 0x00000008, 0x00000007, 0x00000007, 0x00040015, 0x0000000a, 0x00000020, 0x00000001, 0x00040020, 0x0000000b, 0x00000001, 0x0000000a, 0x0004003b, 0x0000000b, 0x0000000c, 0x00000001, 0x0004002b, 0x0000000a, 0x0000000e, 0x00000001, 0x0004002b, 0x0000000a, 0x00000010, 0x00000002, 0x00040017, 0x00000017, 0x00000006, 0x00000004, 0x00040015, 0x00000018, 0x00000020, 0x00000000, 0x0004002b, 0x00000018, 0x00000019, 0x00000001, 0x0004001c, 0x0000001a, 0x00000006, 0x00000019, 0x0006001e, 0x0000001b, 0x00000017, 0x00000006, 0x0000001a, 0x0000001a, 0x00040020, 0x0000001c, 0x00000003, 0x0000001b, 0x0004003b, 0x0000001c, 0x0000001d, 0x00000003, 0x0004002b, 0x0000000a, 0x0000001e, 0x00000000, 0x0004002b, 0x00000006, 0x00000020, 0x40000000, 0x0004002b, 0x00000006, 0x00000022, 0x3f800000, 0x0004002b, 0x00000006, 0x00000025, 0x00000000, 0x00040020, 0x00000029, 0x00000003, 0x00000017, 0x00050036, 0x00000002, 0x00000004, 0x00000000, 0x00000003, 0x000200f8, 0x00000005, 0x0004003b, 0x00000008, 0x00000009, 0x00000007, 0x0004003d, 0x0000000a, 0x0000000d, 0x0000000c, 0x000500c4, 0x0000000a, 0x0000000f, 0x0000000d, 0x0000000e, 0x000500c7, 0x0000000a, 0x00000011, 0x0000000f, 0x00000010, 0x0004006f, 0x00000006, 0x00000012, 0x00000011, 0x0004003d, 0x0000000a, 0x00000013, 0x0000000c, 0x000500c7, 0x0000000a, 0x00000014, 0x00000013, 0x00000010, 0x0004006f, 0x00000006, 0x00000015, 0x00000014, 0x00050050, 0x00000007, 0x00000016, 0x00000012, 0x00000015, 0x0003003e, 0x00000009, 0x00000016, 0x0004003d, 0x00000007, 0x0000001f, 0x00000009, 0x0005008e, 0x00000007, 0x00000021, 0x0000001f, 0x00000020, 0x00050050, 0x00000007, 0x00000023, 0x00000022, 0x00000022, 0x00050083, 0x00000007, 0x00000024, 0x00000021, 0x00000023, 0x00050051, 0x00000006, 0x00000026, 0x00000024, 0x00000000, 0x00050051, 0x00000006, 0x00000027, 0x00000024, 0x00000001, 0x00070050, 0x00000017, 0x00000028, 0x00000026, 0x00000027, 0x00000025, 0x00000022, 0x00050041, 0x00000029, 0x0000002a, 0x0000001d, 0x0000001e, 0x0003003e, 0x0000002a, 0x00000028, 0x000100fd, 0x00010038, };
const frag_spv = [_]u32{ 0x07230203, 0x00010300, 0x0008000b, 0x00000046, 0x00000000, 0x00020011, 0x00000001, 0x0006000b, 0x00000001, 0x4c534c47, 0x6474732e, 0x3035342e, 0x00000000, 0x0003000e, 0x00000000, 0x00000001, 0x0007000f, 0x00000004, 0x00000004, 0x6e69616d, 0x00000000, 0x0000000c, 0x00000040, 0x00030010, 0x00000004, 0x00000007, 0x00030003, 0x00000002, 0x000001c2, 0x00040005, 0x00000004, 0x6e69616d, 0x00000000, 0x00030005, 0x00000009, 0x00007675, 0x00060005, 0x0000000c, 0x465f6c67, 0x43676172, 0x64726f6f, 0x00000000, 0x00040005, 0x0000000f, 0x68737550, 0x00000000, 0x00060006, 0x0000000f, 0x00000000, 0x6f736572, 0x6974756c, 0x00006e6f, 0x00040005, 0x00000011, 0x68737570, 0x00000000, 0x00030005, 0x0000001a, 0x00706f74, 0x00040005, 0x0000001f, 0x74746f62, 0x00006d6f, 0x00040005, 0x00000024, 0x6f6c6f63, 0x00000072, 0x00050005, 0x00000040, 0x5f74756f, 0x6f6c6f63, 0x00000072, 0x00040047, 0x0000000c, 0x0000000b, 0x0000000f, 0x00030047, 0x0000000f, 0x00000002, 0x00050048, 0x0000000f, 0x00000000, 0x00000023, 0x00000000, 0x00040047, 0x00000040, 0x0000001e, 0x00000000, 0x00020013, 0x00000002, 0x00030021, 0x00000003, 0x00000002, 0x00030016, 0x00000006, 0x00000020, 0x00040017, 0x00000007, 0x00000006, 0x00000002, 0x00040020, 0x00000008, 0x00000007, 0x00000007, 0x00040017, 0x0000000a, 0x00000006, 0x00000004, 0x00040020, 0x0000000b, 0x00000001, 0x0000000a, 0x0004003b, 0x0000000b, 0x0000000c, 0x00000001, 0x0003001e, 0x0000000f, 0x00000007, 0x00040020, 0x00000010, 0x00000009, 0x0000000f, 0x0004003b, 0x00000010, 0x00000011, 0x00000009, 0x00040015, 0x00000012, 0x00000020, 0x00000001, 0x0004002b, 0x00000012, 0x00000013, 0x00000000, 0x00040020, 0x00000014, 0x00000009, 0x00000007, 0x00040017, 0x00000018, 0x00000006, 0x00000003, 0x00040020, 0x00000019, 0x00000007, 0x00000018, 0x0004002b, 0x00000006, 0x0000001b, 0x3dcccccd, 0x0004002b, 0x00000006, 0x0000001c, 0x3ea3d70a, 0x0004002b, 0x00000006, 0x0000001d, 0x3f3851ec, 0x0006002c, 0x00000018, 0x0000001e, 0x0000001b, 0x0000001c, 0x0000001d, 0x0004002b, 0x00000006, 0x00000020, 0x3f6b851f, 0x0004002b, 0x00000006, 0x00000021, 0x3ec28f5c, 0x0004002b, 0x00000006, 0x00000022, 0x3e23d70a, 0x0006002c, 0x00000018, 0x00000023, 0x00000020, 0x00000021, 0x00000022, 0x00040015, 0x00000027, 0x00000020, 0x00000000, 0x0004002b, 0x00000027, 0x00000028, 0x00000001, 0x00040020, 0x00000029, 0x00000007, 0x00000006, 0x0004002b, 0x00000006, 0x0000002f, 0x3e4ccccd, 0x0004002b, 0x00000006, 0x00000030, 0x3f59999a, 0x0004002b, 0x00000006, 0x00000031, 0x3f0ccccd, 0x0006002c, 0x00000018, 0x00000032, 0x0000002f, 0x00000030, 0x00000031, 0x0004002b, 0x00000006, 0x00000033, 0x3eb33333, 0x0004002b, 0x00000006, 0x00000034, 0x3f800000, 0x0004002b, 0x00000027, 0x00000035, 0x00000000, 0x00040020, 0x0000003f, 0x00000003, 0x0000000a, 0x0004003b, 0x0000003f, 0x00000040, 0x00000003, 0x00050036, 0x00000002, 0x00000004, 0x00000000, 0x00000003, 0x000200f8, 0x00000005, 0x0004003b, 0x00000008, 0x00000009, 0x00000007, 0x0004003b, 0x00000019, 0x0000001a, 0x00000007, 0x0004003b, 0x00000019, 0x0000001f, 0x00000007, 0x0004003b, 0x00000019, 0x00000024, 0x00000007, 0x0004003d, 0x0000000a, 0x0000000d, 0x0000000c, 0x0007004f, 0x00000007, 0x0000000e, 0x0000000d, 0x0000000d, 0x00000000, 0x00000001, 0x00050041, 0x00000014, 0x00000015, 0x00000011, 0x00000013, 0x0004003d, 0x00000007, 0x00000016, 0x00000015, 0x00050088, 0x00000007, 0x00000017, 0x0000000e, 0x00000016, 0x0003003e, 0x00000009, 0x00000017, 0x0003003e, 0x0000001a, 0x0000001e, 0x0003003e, 0x0000001f, 0x00000023, 0x0004003d, 0x00000018, 0x00000025, 0x0000001f, 0x0004003d, 0x00000018, 0x00000026, 0x0000001a, 0x00050041, 0x00000029, 0x0000002a, 0x00000009, 0x00000028, 0x0004003d, 0x00000006, 0x0000002b, 0x0000002a, 0x00060050, 0x00000018, 0x0000002c, 0x0000002b, 0x0000002b, 0x0000002b, 0x0008000c, 0x00000018, 0x0000002d, 0x00000001, 0x0000002e, 0x00000025, 0x00000026, 0x0000002c, 0x0003003e, 0x00000024, 0x0000002d, 0x0004003d, 0x00000018, 0x0000002e, 0x00000024, 0x00050041, 0x00000029, 0x00000036, 0x00000009, 0x00000035, 0x0004003d, 0x00000006, 0x00000037, 0x00000036, 0x00050083, 0x00000006, 0x00000038, 0x00000034, 0x00000037, 0x00050085, 0x00000006, 0x00000039, 0x00000033, 0x00000038, 0x00050041, 0x00000029, 0x0000003a, 0x00000009, 0x00000028, 0x0004003d, 0x00000006, 0x0000003b, 0x0000003a, 0x00050085, 0x00000006, 0x0000003c, 0x00000039, 0x0000003b, 0x00060050, 0x00000018, 0x0000003d, 0x0000003c, 0x0000003c, 0x0000003c, 0x0008000c, 0x00000018, 0x0000003e, 0x00000001, 0x0000002e, 0x0000002e, 0x00000032, 0x0000003d, 0x0003003e, 0x00000024, 0x0000003e, 0x0004003d, 0x00000018, 0x00000041, 0x00000024, 0x00050051, 0x00000006, 0x00000042, 0x00000041, 0x00000000, 0x00050051, 0x00000006, 0x00000043, 0x00000041, 0x00000001, 0x00050051, 0x00000006, 0x00000044, 0x00000041, 0x00000002, 0x00070050, 0x0000000a, 0x00000045, 0x00000042, 0x00000043, 0x00000044, 0x00000034, 0x0003003e, 0x00000040, 0x00000045, 0x000100fd, 0x00010038, };
// Vulkan types, constants and command signatures come from the official
// headers. VK_NO_PROTOTYPES keeps the headers from declaring the commands, so
// libvulkan is still loaded with dlopen and the entry points are resolved with
// vkGetInstanceProcAddr / vkGetDeviceProcAddr (same approach as 4_egl_gl.zig).
const vk = @cImport({
    @cDefine("VK_NO_PROTOTYPES", "1");
    @cInclude("vulkan/vulkan.h");
});

/// The header declares `PFN_<name>` as an optional pointer; the example stores
/// resolved entry points as non-optional function pointers.
fn Proc(comptime name: []const u8) type {
    return @typeInfo(@field(vk, "PFN_" ++ name)).optional.child;
}

fn fetch(get_proc: anytype, handle: anytype, comptime name: [:0]const u8) Proc(name) {
    const raw = get_proc(handle, name) orelse @panic("Vulkan function not found: " ++ name);
    return @ptrCast(raw);
}

/// Resolved Vulkan commands. The fields are named like the C functions so the
/// call sites can be checked against the Vulkan reference.
const Api = struct {
    vkGetInstanceProcAddr: Proc("vkGetInstanceProcAddr"),
    vkGetDeviceProcAddr: Proc("vkGetDeviceProcAddr") = undefined,

    vkCreateInstance: Proc("vkCreateInstance"),
    vkDestroyInstance: Proc("vkDestroyInstance") = undefined,
    vkEnumeratePhysicalDevices: Proc("vkEnumeratePhysicalDevices") = undefined,
    vkEnumerateDeviceExtensionProperties: Proc("vkEnumerateDeviceExtensionProperties") = undefined,
    vkGetPhysicalDeviceQueueFamilyProperties: Proc("vkGetPhysicalDeviceQueueFamilyProperties") = undefined,
    vkGetPhysicalDeviceImageFormatProperties: Proc("vkGetPhysicalDeviceImageFormatProperties") = undefined,
    vkGetPhysicalDeviceMemoryProperties: Proc("vkGetPhysicalDeviceMemoryProperties") = undefined,
    vkCreateDevice: Proc("vkCreateDevice") = undefined,
    vkDestroyDevice: Proc("vkDestroyDevice") = undefined,
    vkGetDeviceQueue: Proc("vkGetDeviceQueue") = undefined,
    vkCreateImage: Proc("vkCreateImage") = undefined,
    vkDestroyImage: Proc("vkDestroyImage") = undefined,
    vkGetImageMemoryRequirements: Proc("vkGetImageMemoryRequirements") = undefined,
    vkGetImageSubresourceLayout: Proc("vkGetImageSubresourceLayout") = undefined,
    vkAllocateMemory: Proc("vkAllocateMemory") = undefined,
    vkFreeMemory: Proc("vkFreeMemory") = undefined,
    vkBindImageMemory: Proc("vkBindImageMemory") = undefined,
    vkGetMemoryFdKHR: Proc("vkGetMemoryFdKHR") = undefined,
    vkCreateImageView: Proc("vkCreateImageView") = undefined,
    vkDestroyImageView: Proc("vkDestroyImageView") = undefined,
    vkCreateRenderPass: Proc("vkCreateRenderPass") = undefined,
    vkDestroyRenderPass: Proc("vkDestroyRenderPass") = undefined,
    vkCreateShaderModule: Proc("vkCreateShaderModule") = undefined,
    vkDestroyShaderModule: Proc("vkDestroyShaderModule") = undefined,
    vkCreatePipelineLayout: Proc("vkCreatePipelineLayout") = undefined,
    vkDestroyPipelineLayout: Proc("vkDestroyPipelineLayout") = undefined,
    vkCreateGraphicsPipelines: Proc("vkCreateGraphicsPipelines") = undefined,
    vkDestroyPipeline: Proc("vkDestroyPipeline") = undefined,
    vkCreateFramebuffer: Proc("vkCreateFramebuffer") = undefined,
    vkDestroyFramebuffer: Proc("vkDestroyFramebuffer") = undefined,
    vkCreateCommandPool: Proc("vkCreateCommandPool") = undefined,
    vkDestroyCommandPool: Proc("vkDestroyCommandPool") = undefined,
    vkAllocateCommandBuffers: Proc("vkAllocateCommandBuffers") = undefined,
    vkBeginCommandBuffer: Proc("vkBeginCommandBuffer") = undefined,
    vkEndCommandBuffer: Proc("vkEndCommandBuffer") = undefined,
    vkCmdBeginRenderPass: Proc("vkCmdBeginRenderPass") = undefined,
    vkCmdBindPipeline: Proc("vkCmdBindPipeline") = undefined,
    vkCmdPushConstants: Proc("vkCmdPushConstants") = undefined,
    vkCmdDraw: Proc("vkCmdDraw") = undefined,
    vkCmdEndRenderPass: Proc("vkCmdEndRenderPass") = undefined,
    vkQueueSubmit: Proc("vkQueueSubmit") = undefined,
    vkQueueWaitIdle: Proc("vkQueueWaitIdle") = undefined,
    vkDeviceWaitIdle: Proc("vkDeviceWaitIdle") = undefined,

    fn load(lib: *std.DynLib) Api {
        const gipa = lib.lookup(Proc("vkGetInstanceProcAddr"), "vkGetInstanceProcAddr") orelse
            @panic("vkGetInstanceProcAddr not found in libvulkan");
        return .{
            .vkGetInstanceProcAddr = gipa,
            .vkCreateInstance = fetch(gipa, null, "vkCreateInstance"),
        };
    }

    fn loadInstance(self: *Api, instance: vk.VkInstance) void {
        const gipa = self.vkGetInstanceProcAddr;
        self.vkGetDeviceProcAddr = fetch(gipa, instance, "vkGetDeviceProcAddr");
        self.vkDestroyInstance = fetch(gipa, instance, "vkDestroyInstance");
        self.vkEnumeratePhysicalDevices = fetch(gipa, instance, "vkEnumeratePhysicalDevices");
        self.vkEnumerateDeviceExtensionProperties = fetch(gipa, instance, "vkEnumerateDeviceExtensionProperties");
        self.vkGetPhysicalDeviceQueueFamilyProperties = fetch(gipa, instance, "vkGetPhysicalDeviceQueueFamilyProperties");
        self.vkGetPhysicalDeviceImageFormatProperties = fetch(gipa, instance, "vkGetPhysicalDeviceImageFormatProperties");
        self.vkGetPhysicalDeviceMemoryProperties = fetch(gipa, instance, "vkGetPhysicalDeviceMemoryProperties");
        self.vkCreateDevice = fetch(gipa, instance, "vkCreateDevice");
    }

    fn loadDevice(self: *Api, device: vk.VkDevice) void {
        const gdpa = self.vkGetDeviceProcAddr;
        self.vkDestroyDevice = fetch(gdpa, device, "vkDestroyDevice");
        self.vkGetDeviceQueue = fetch(gdpa, device, "vkGetDeviceQueue");
        self.vkCreateImage = fetch(gdpa, device, "vkCreateImage");
        self.vkDestroyImage = fetch(gdpa, device, "vkDestroyImage");
        self.vkGetImageMemoryRequirements = fetch(gdpa, device, "vkGetImageMemoryRequirements");
        self.vkGetImageSubresourceLayout = fetch(gdpa, device, "vkGetImageSubresourceLayout");
        self.vkAllocateMemory = fetch(gdpa, device, "vkAllocateMemory");
        self.vkFreeMemory = fetch(gdpa, device, "vkFreeMemory");
        self.vkBindImageMemory = fetch(gdpa, device, "vkBindImageMemory");
        self.vkGetMemoryFdKHR = fetch(gdpa, device, "vkGetMemoryFdKHR");
        self.vkCreateImageView = fetch(gdpa, device, "vkCreateImageView");
        self.vkDestroyImageView = fetch(gdpa, device, "vkDestroyImageView");
        self.vkCreateRenderPass = fetch(gdpa, device, "vkCreateRenderPass");
        self.vkDestroyRenderPass = fetch(gdpa, device, "vkDestroyRenderPass");
        self.vkCreateShaderModule = fetch(gdpa, device, "vkCreateShaderModule");
        self.vkDestroyShaderModule = fetch(gdpa, device, "vkDestroyShaderModule");
        self.vkCreatePipelineLayout = fetch(gdpa, device, "vkCreatePipelineLayout");
        self.vkDestroyPipelineLayout = fetch(gdpa, device, "vkDestroyPipelineLayout");
        self.vkCreateGraphicsPipelines = fetch(gdpa, device, "vkCreateGraphicsPipelines");
        self.vkDestroyPipeline = fetch(gdpa, device, "vkDestroyPipeline");
        self.vkCreateFramebuffer = fetch(gdpa, device, "vkCreateFramebuffer");
        self.vkDestroyFramebuffer = fetch(gdpa, device, "vkDestroyFramebuffer");
        self.vkCreateCommandPool = fetch(gdpa, device, "vkCreateCommandPool");
        self.vkDestroyCommandPool = fetch(gdpa, device, "vkDestroyCommandPool");
        self.vkAllocateCommandBuffers = fetch(gdpa, device, "vkAllocateCommandBuffers");
        self.vkBeginCommandBuffer = fetch(gdpa, device, "vkBeginCommandBuffer");
        self.vkEndCommandBuffer = fetch(gdpa, device, "vkEndCommandBuffer");
        self.vkCmdBeginRenderPass = fetch(gdpa, device, "vkCmdBeginRenderPass");
        self.vkCmdBindPipeline = fetch(gdpa, device, "vkCmdBindPipeline");
        self.vkCmdPushConstants = fetch(gdpa, device, "vkCmdPushConstants");
        self.vkCmdDraw = fetch(gdpa, device, "vkCmdDraw");
        self.vkCmdEndRenderPass = fetch(gdpa, device, "vkCmdEndRenderPass");
        self.vkQueueSubmit = fetch(gdpa, device, "vkQueueSubmit");
        self.vkQueueWaitIdle = fetch(gdpa, device, "vkQueueWaitIdle");
        self.vkDeviceWaitIdle = fetch(gdpa, device, "vkDeviceWaitIdle");
    }
};

fn vkCheck(res: vk.VkResult, what: []const u8) !void {
    if (res != vk.VK_SUCCESS) {
        std.debug.print("Vulkan: {s} failed ({})\n", .{ what, res });
        return error.VulkanFailed;
    }
}

const Gpu = struct {
    lib: std.DynLib,
    api: Api,
    instance: vk.VkInstance,
    device: vk.VkDevice,
    queue: vk.VkQueue,
    command_pool: vk.VkCommandPool,
    command_buffer: vk.VkCommandBuffer,
    render_pass: vk.VkRenderPass,
    pipeline_layout: vk.VkPipelineLayout,
    pipeline: vk.VkPipeline,
    vert_module: vk.VkShaderModule,
    frag_module: vk.VkShaderModule,
    framebuffer: vk.VkFramebuffer,
    image_view: vk.VkImageView,
    image: vk.VkImage,
    memory: vk.VkDeviceMemory,
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

        var api = Api.load(&lib);

        const app_info = std.mem.zeroInit(vk.VkApplicationInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pApplicationName = "columbus-vulkan",
            .pEngineName = "none",
            .apiVersion = vk.VK_API_VERSION_1_0,
        });
        const instance_info = std.mem.zeroInit(vk.VkInstanceCreateInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pApplicationInfo = &app_info,
        });
        var instance: vk.VkInstance = null;
        try vkCheck(api.vkCreateInstance(&instance_info, null, &instance), "vkCreateInstance");
        api.loadInstance(instance);

        // Pick a physical device that can render into a linear ARGB8888 image.
        var device_count: u32 = 0;
        try vkCheck(api.vkEnumeratePhysicalDevices(instance, &device_count, null), "vkEnumeratePhysicalDevices");
        var physicals: [8]vk.VkPhysicalDevice = undefined;
        device_count = @min(device_count, physicals.len);
        try vkCheck(api.vkEnumeratePhysicalDevices(instance, &device_count, &physicals), "vkEnumeratePhysicalDevices");

        var physical: vk.VkPhysicalDevice = null;
        var queue_family: u32 = 0;
        for (physicals[0..device_count]) |candidate| {
            var format_props: vk.VkImageFormatProperties = undefined;
            const format_ok = api.vkGetPhysicalDeviceImageFormatProperties(
                candidate,
                vk.VK_FORMAT_B8G8R8A8_UNORM,
                vk.VK_IMAGE_TYPE_2D,
                vk.VK_IMAGE_TILING_LINEAR,
                vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
                0,
                &format_props,
            ) == vk.VK_SUCCESS;

            var families: [16]vk.VkQueueFamilyProperties = undefined;
            var family_count: u32 = families.len;
            api.vkGetPhysicalDeviceQueueFamilyProperties(candidate, &family_count, &families);
            var graphics: ?u32 = null;
            for (families[0..family_count], 0..) |f, i| {
                if (f.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT != 0) {
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
        try checkDeviceExtensions(&api, physical, &required_exts);

        const priority: f32 = 1;
        const queue_info = std.mem.zeroInit(vk.VkDeviceQueueCreateInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = queue_family,
            .queueCount = 1,
            .pQueuePriorities = &priority,
        });
        const device_info = std.mem.zeroInit(vk.VkDeviceCreateInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &queue_info,
            .enabledExtensionCount = required_exts.len,
            .ppEnabledExtensionNames = &required_exts,
        });
        var device: vk.VkDevice = null;
        try vkCheck(api.vkCreateDevice(physical, &device_info, null, &device), "vkCreateDevice");
        api.loadDevice(device);

        var queue: vk.VkQueue = null;
        api.vkGetDeviceQueue(device, queue_family, 0, &queue);

        // Render target: a linear B8G8R8A8 image whose memory can be exported as
        // a dma-buf. The render pass below writes the gradient into it.
        const external_info = std.mem.zeroInit(vk.VkExternalMemoryImageCreateInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
            .handleTypes = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
        });
        const image_info = std.mem.zeroInit(vk.VkImageCreateInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = &external_info,
            .imageType = vk.VK_IMAGE_TYPE_2D,
            .format = vk.VK_FORMAT_B8G8R8A8_UNORM,
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = vk.VK_SAMPLE_COUNT_1_BIT,
            .tiling = vk.VK_IMAGE_TILING_LINEAR,
            .usage = vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        });
        var image: vk.VkImage = null;
        try vkCheck(api.vkCreateImage(device, &image_info, null, &image), "vkCreateImage");

        var requirements: vk.VkMemoryRequirements = undefined;
        api.vkGetImageMemoryRequirements(device, image, &requirements);

        var memory_props: vk.VkPhysicalDeviceMemoryProperties = undefined;
        api.vkGetPhysicalDeviceMemoryProperties(physical, &memory_props);
        var memory_type: ?u32 = null;
        for (memory_props.memoryTypes[0..memory_props.memoryTypeCount], 0..) |t, i| {
            if (requirements.memoryTypeBits & (@as(u32, 1) << @intCast(i)) == 0) continue;
            if (t.propertyFlags & vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT != 0) {
                memory_type = @intCast(i);
                break;
            }
        }
        const memory_type_index = memory_type orelse @panic("no device-local memory type for dma-buf image");

        const dedicated = std.mem.zeroInit(vk.VkMemoryDedicatedAllocateInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO,
            .image = image,
        });
        const export_info = std.mem.zeroInit(vk.VkExportMemoryAllocateInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO,
            .pNext = &dedicated,
            .handleTypes = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
        });
        const alloc_info = std.mem.zeroInit(vk.VkMemoryAllocateInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = &export_info,
            .allocationSize = requirements.size,
            .memoryTypeIndex = memory_type_index,
        });
        var memory: vk.VkDeviceMemory = null;
        try vkCheck(api.vkAllocateMemory(device, &alloc_info, null, &memory), "vkAllocateMemory");
        try vkCheck(api.vkBindImageMemory(device, image, memory, 0), "vkBindImageMemory");

        var fd: i32 = -1;
        const fd_info = std.mem.zeroInit(vk.VkMemoryGetFdInfoKHR, .{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR,
            .memory = memory,
            .handleType = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
        });
        try vkCheck(api.vkGetMemoryFdKHR(device, &fd_info, &fd), "vkGetMemoryFdKHR");

        const subresource = std.mem.zeroInit(vk.VkImageSubresource, .{
            .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
        });
        var layout: vk.VkSubresourceLayout = undefined;
        api.vkGetImageSubresourceLayout(device, image, &subresource, &layout);

        const image_view_info = std.mem.zeroInit(vk.VkImageViewCreateInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = image,
            .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
            .format = vk.VK_FORMAT_B8G8R8A8_UNORM,
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .levelCount = 1,
                .layerCount = 1,
            },
        });
        var image_view: vk.VkImageView = null;
        try vkCheck(api.vkCreateImageView(device, &image_view_info, null, &image_view), "vkCreateImageView");

        const color_ref = std.mem.zeroInit(vk.VkAttachmentReference, .{
            .layout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        });
        const subpass = std.mem.zeroInit(vk.VkSubpassDescription, .{
            .pipelineBindPoint = vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_ref,
        });
        const attachment = std.mem.zeroInit(vk.VkAttachmentDescription, .{
            .format = vk.VK_FORMAT_B8G8R8A8_UNORM,
            .samples = vk.VK_SAMPLE_COUNT_1_BIT,
            .loadOp = vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = vk.VK_ATTACHMENT_STORE_OP_STORE,
            .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = vk.VK_IMAGE_LAYOUT_GENERAL,
        });
        const render_pass_info = std.mem.zeroInit(vk.VkRenderPassCreateInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
            .attachmentCount = 1,
            .pAttachments = &attachment,
            .subpassCount = 1,
            .pSubpasses = &subpass,
        });
        var render_pass: vk.VkRenderPass = null;
        try vkCheck(api.vkCreateRenderPass(device, &render_pass_info, null, &render_pass), "vkCreateRenderPass");

        const framebuffer_info = std.mem.zeroInit(vk.VkFramebufferCreateInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .renderPass = render_pass,
            .attachmentCount = 1,
            .pAttachments = &image_view,
            .width = width,
            .height = height,
            .layers = 1,
        });
        var framebuffer: vk.VkFramebuffer = null;
        try vkCheck(api.vkCreateFramebuffer(device, &framebuffer_info, null, &framebuffer), "vkCreateFramebuffer");

        const vert_module = try createShaderModule(&api, device, &vert_spv);
        const frag_module = try createShaderModule(&api, device, &frag_spv);

        const push_range = std.mem.zeroInit(vk.VkPushConstantRange, .{
            .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            .size = @sizeOf([2]f32),
        });
        const pipeline_layout_info = std.mem.zeroInit(vk.VkPipelineLayoutCreateInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pushConstantRangeCount = 1,
            .pPushConstantRanges = &push_range,
        });
        var pipeline_layout: vk.VkPipelineLayout = null;
        try vkCheck(api.vkCreatePipelineLayout(device, &pipeline_layout_info, null, &pipeline_layout), "vkCreatePipelineLayout");

        const ShaderStage = vk.VkPipelineShaderStageCreateInfo;
        const stages = [_]ShaderStage{
            std.mem.zeroInit(ShaderStage, .{
                .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .stage = vk.VK_SHADER_STAGE_VERTEX_BIT,
                .module = vert_module,
                .pName = "main",
            }),
            std.mem.zeroInit(ShaderStage, .{
                .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .stage = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
                .module = frag_module,
                .pName = "main",
            }),
        };
        const vertex_input = std.mem.zeroInit(vk.VkPipelineVertexInputStateCreateInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        });
        const input_assembly = std.mem.zeroInit(vk.VkPipelineInputAssemblyStateCreateInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .topology = vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        });
        const viewport = std.mem.zeroInit(vk.VkViewport, .{
            .width = @as(f32, @floatFromInt(width)),
            .height = @as(f32, @floatFromInt(height)),
            .maxDepth = 1,
        });
        const target_rect = std.mem.zeroInit(vk.VkRect2D, .{
            .extent = .{ .width = width, .height = height },
        });
        const viewport_state = std.mem.zeroInit(vk.VkPipelineViewportStateCreateInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .viewportCount = 1,
            .pViewports = &viewport,
            .scissorCount = 1,
            .pScissors = &target_rect,
        });
        const rasterization = std.mem.zeroInit(vk.VkPipelineRasterizationStateCreateInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .polygonMode = vk.VK_POLYGON_MODE_FILL,
            .cullMode = vk.VK_CULL_MODE_NONE,
            .frontFace = vk.VK_FRONT_FACE_COUNTER_CLOCKWISE,
            .lineWidth = 1,
        });
        const multisample = std.mem.zeroInit(vk.VkPipelineMultisampleStateCreateInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .rasterizationSamples = vk.VK_SAMPLE_COUNT_1_BIT,
        });
        const blend_attachment = std.mem.zeroInit(vk.VkPipelineColorBlendAttachmentState, .{
            .colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT | vk.VK_COLOR_COMPONENT_G_BIT |
                vk.VK_COLOR_COMPONENT_B_BIT | vk.VK_COLOR_COMPONENT_A_BIT,
        });
        const color_blend = std.mem.zeroInit(vk.VkPipelineColorBlendStateCreateInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .attachmentCount = 1,
            .pAttachments = &blend_attachment,
        });
        const pipeline_info = std.mem.zeroInit(vk.VkGraphicsPipelineCreateInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
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
            .basePipelineIndex = -1,
        });
        var pipeline: vk.VkPipeline = null;
        try vkCheck(api.vkCreateGraphicsPipelines(device, null, 1, &pipeline_info, null, &pipeline), "vkCreateGraphicsPipelines");

        const pool_info = std.mem.zeroInit(vk.VkCommandPoolCreateInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .queueFamilyIndex = queue_family,
        });
        var command_pool: vk.VkCommandPool = null;
        try vkCheck(api.vkCreateCommandPool(device, &pool_info, null, &command_pool), "vkCreateCommandPool");

        const buffer_alloc_info = std.mem.zeroInit(vk.VkCommandBufferAllocateInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = command_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        });
        var command_buffer: vk.VkCommandBuffer = null;
        try vkCheck(api.vkAllocateCommandBuffers(device, &buffer_alloc_info, &command_buffer), "vkAllocateCommandBuffers");

        const begin_info = std.mem.zeroInit(vk.VkCommandBufferBeginInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        });
        try vkCheck(api.vkBeginCommandBuffer(command_buffer, &begin_info), "vkBeginCommandBuffer");
        const pass_begin = std.mem.zeroInit(vk.VkRenderPassBeginInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .renderPass = render_pass,
            .framebuffer = framebuffer,
            .renderArea = target_rect,
        });
        api.vkCmdBeginRenderPass(command_buffer, &pass_begin, vk.VK_SUBPASS_CONTENTS_INLINE);
        api.vkCmdBindPipeline(command_buffer, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
        const resolution = [2]f32{ @floatFromInt(width), @floatFromInt(height) };
        api.vkCmdPushConstants(command_buffer, pipeline_layout, vk.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(@TypeOf(resolution)), &resolution);
        api.vkCmdDraw(command_buffer, 3, 1, 0, 0);
        api.vkCmdEndRenderPass(command_buffer);
        try vkCheck(api.vkEndCommandBuffer(command_buffer), "vkEndCommandBuffer");

        return .{
            .lib = lib,
            .api = api,
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
        var cmd = [_]vk.VkCommandBuffer{self.command_buffer};
        const submit = std.mem.zeroInit(vk.VkSubmitInfo, .{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .commandBufferCount = 1,
            .pCommandBuffers = &cmd,
        });
        try vkCheck(self.api.vkQueueSubmit(self.queue, 1, &submit, null), "vkQueueSubmit");
        try vkCheck(self.api.vkQueueWaitIdle(self.queue), "vkQueueWaitIdle");
    }

    pub fn deinit(self: *Gpu) void {
        const api = self.api;
        _ = api.vkDeviceWaitIdle(self.device);
        api.vkDestroyPipeline(self.device, self.pipeline, null);
        api.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
        api.vkDestroyFramebuffer(self.device, self.framebuffer, null);
        api.vkDestroyRenderPass(self.device, self.render_pass, null);
        api.vkDestroyImageView(self.device, self.image_view, null);
        api.vkDestroyShaderModule(self.device, self.vert_module, null);
        api.vkDestroyShaderModule(self.device, self.frag_module, null);
        api.vkDestroyCommandPool(self.device, self.command_pool, null);
        api.vkDestroyImage(self.device, self.image, null);
        api.vkFreeMemory(self.device, self.memory, null);
        api.vkDestroyDevice(self.device, null);
        api.vkDestroyInstance(self.instance, null);
        _ = std.os.linux.close(self.fd);
        self.lib.close();
    }
};

fn createShaderModule(api: *const Api, device: vk.VkDevice, code: []const u32) !vk.VkShaderModule {
    const info = std.mem.zeroInit(vk.VkShaderModuleCreateInfo, .{
        .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = code.len * @sizeOf(u32),
        .pCode = code.ptr,
    });
    var module: vk.VkShaderModule = null;
    try vkCheck(api.vkCreateShaderModule(device, &info, null, &module), "vkCreateShaderModule");
    return module;
}

fn checkDeviceExtensions(api: *const Api, physical: vk.VkPhysicalDevice, required: []const [*:0]const u8) !void {
    var count: u32 = 0;
    _ = api.vkEnumerateDeviceExtensionProperties(physical, null, &count, null);
    var props: [128]vk.VkExtensionProperties = undefined;
    count = @min(count, props.len);
    _ = api.vkEnumerateDeviceExtensionProperties(physical, null, &count, &props);

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
