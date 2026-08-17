/* The native macOS graphics service for std.ui/std.gpu.
 *
 * This file is deliberately a small Objective-C boundary. Luce sees only
 * integer handles and the ABI callback vocabulary; AppKit and Metal remain
 * on this side of that seam. It is compiled only for the macOS loom/start
 * targets.
 */

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

enum {
    luce_yes = 1,
    luce_no = 0,
    luce_exhausted = -1,
    luce_window_kind = 1,
    luce_surface_kind = 2,
    luce_max_windows = 64,
    luce_max_surfaces = 128,
    luce_max_rects = 2048,
};

typedef struct {
    float position[2];
    float color[4];
} LuceVertex;

typedef struct {
    int64_t x;
    int64_t y;
    int64_t width;
    int64_t height;
    float color[4];
} LuceRect;

typedef struct {
    NSWindow *window;
    CALayer *layer;
    int64_t width;
    int64_t height;
    /* A Surface keeps the window's native layer usable after the Luce
     * Window value has gone out of scope.  The host therefore keeps the
     * window object alive until the last derived surface releases it. */
    size_t surface_refs;
    int close_requested;
    int alive;
} LuceWindow;

typedef struct {
    CALayer *layer;
    int64_t window;
    int64_t width;
    int64_t height;
    uint8_t *pixels;
    size_t pixel_bytes;
    double clear[4];
    LuceRect rects[luce_max_rects];
    size_t rect_count;
    int alive;
} LuceSurface;

typedef struct {
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLRenderPipelineState> pipeline;
    LuceWindow windows[luce_max_windows];
    LuceSurface surfaces[luce_max_surfaces];
} LuceGraphics;

static void luce_release_window(LuceWindow *slot) {
    if (!slot->alive) return;
    if (slot->surface_refs != 0) return;
    [slot->window orderOut:nil];
    [slot->window close];
    [slot->window release];
    [slot->layer release];
    memset(slot, 0, sizeof(*slot));
}

static void luce_release_surface(LuceSurface *slot) {
    if (!slot->alive) return;
    if (slot->pixels != NULL) [slot->layer setContents:nil];
    [slot->layer release];
    free(slot->pixels);
    memset(slot, 0, sizeof(*slot));
}

static LuceWindow *luce_window(LuceGraphics *graphics, int64_t handle) {
    if (handle <= 0 || handle > luce_max_windows) return NULL;
    LuceWindow *slot = &graphics->windows[handle - 1];
    return slot->alive ? slot : NULL;
}

static void luce_request_window_close(LuceWindow *slot) {
    if (!slot->alive) return;
    if (!slot->close_requested) {
        slot->close_requested = 1;
        [slot->window orderOut:nil];
        [slot->window close];
    }
    luce_release_window(slot);
}

static LuceSurface *luce_surface(LuceGraphics *graphics, int64_t handle) {
    if (handle <= 0 || handle > luce_max_surfaces) return NULL;
    LuceSurface *slot = &graphics->surfaces[handle - 1];
    return slot->alive ? slot : NULL;
}

static int64_t luce_next_window(LuceGraphics *graphics) {
    for (int64_t index = 0; index < luce_max_windows; index++) {
        if (!graphics->windows[index].alive) return index + 1;
    }
    return 0;
}

static int64_t luce_next_surface(LuceGraphics *graphics) {
    for (int64_t index = 0; index < luce_max_surfaces; index++) {
        if (!graphics->surfaces[index].alive) return index + 1;
    }
    return 0;
}

static void luce_surface_released(LuceGraphics *graphics, LuceSurface *surface) {
    const int64_t window_handle = surface->window;
    luce_release_surface(surface);
    LuceWindow *window = luce_window(graphics, window_handle);
    if (window != NULL && window->surface_refs != 0) {
        window->surface_refs -= 1;
        luce_release_window(window);
    }
}

static id<MTLRenderPipelineState> luce_make_pipeline(id<MTLDevice> device) {
    static NSString *source =
        @"#include <metal_stdlib>\n"
         "using namespace metal;\n"
         "struct Vertex { float2 position; float4 color; };\n"
         "struct Output { float4 position [[position]]; float4 color; };\n"
         "vertex Output luce_vertex(const device Vertex *vertices [[buffer(0)]], uint id [[vertex_id]]) {\n"
         "    Output output;\n"
         "    output.position = float4(vertices[id].position, 0.0, 1.0);\n"
         "    output.color = vertices[id].color;\n"
         "    return output;\n"
         "}\n"
         "fragment float4 luce_fragment(Output input [[stage_in]]) { return input.color; }\n";

    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    if (library == nil) return nil;
    id<MTLFunction> vertex = [library newFunctionWithName:@"luce_vertex"];
    id<MTLFunction> fragment = [library newFunctionWithName:@"luce_fragment"];
    if (vertex == nil || fragment == nil) {
        [vertex release];
        [fragment release];
        [library release];
        return nil;
    }

    MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.vertexFunction = vertex;
    descriptor.fragmentFunction = fragment;
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    [descriptor release];
    [vertex release];
    [fragment release];
    [library release];
    return pipeline;
}

void *luce_macos_graphics_create(void) {
    @autoreleasepool {
        LuceGraphics *graphics = calloc(1, sizeof(*graphics));
        if (graphics == NULL) return NULL;
        graphics->device = MTLCreateSystemDefaultDevice();
        if (graphics->device != nil) {
            graphics->queue = [graphics->device newCommandQueue];
            graphics->pipeline = luce_make_pipeline(graphics->device);
        }
        return graphics;
    }
}

void luce_macos_graphics_destroy(void *opaque) {
    if (opaque == NULL) return;
    @autoreleasepool {
        LuceGraphics *graphics = opaque;
        for (int index = 0; index < luce_max_surfaces; index++) {
            if (graphics->surfaces[index].alive) {
                luce_surface_released(graphics, &graphics->surfaces[index]);
            }
        }
        for (int index = 0; index < luce_max_windows; index++) luce_release_window(&graphics->windows[index]);
        [graphics->pipeline release];
        [graphics->queue release];
        [graphics->device release];
        free(graphics);
    }
}

int luce_macos_graphics_backend(void *opaque, int64_t *backend) {
    if (opaque == NULL || backend == NULL) return luce_no;
    LuceGraphics *graphics = opaque;
    *backend = (graphics->device != nil && graphics->queue != nil && graphics->pipeline != nil) ?
        0 : 2; /* Metal, or the CPU window fallback */
    return luce_yes;
}

int luce_macos_graphics_window_open(
    void *opaque,
    const uint8_t *title,
    int64_t title_length,
    int64_t width,
    int64_t height,
    int64_t *handle
) {
    if (opaque == NULL || title == NULL || handle == NULL || title_length < 0 ||
        width <= 0 || height <= 0 || width > 16384 || height > 16384) return luce_no;
    @autoreleasepool {
        LuceGraphics *graphics = opaque;
        NSApplication *application = [NSApplication sharedApplication];
        [application setActivationPolicy:NSApplicationActivationPolicyRegular];
        int64_t number = luce_next_window(graphics);
        if (number == 0) return luce_exhausted;
        NSString *name = [[NSString alloc] initWithBytes:title length:(NSUInteger)title_length encoding:NSUTF8StringEncoding];
        if (name == nil) return luce_no;

        NSRect frame = NSMakeRect(0, 0, (CGFloat)width, (CGFloat)height);
        NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
            NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable;
        NSWindow *window = [[NSWindow alloc] initWithContentRect:frame styleMask:style
            backing:NSBackingStoreBuffered defer:NO];
        NSView *view = [[NSView alloc] initWithFrame:frame];
        const int metal = graphics->device != nil && graphics->queue != nil && graphics->pipeline != nil;
        CALayer *layer = metal
            ? [[CAMetalLayer layer] retain]
            : [[CALayer layer] retain];
        if (window == nil || view == nil || layer == nil) {
            [layer release];
            [view release];
            [window release];
            [name release];
            return luce_no;
        }

        window.releasedWhenClosed = NO;
        window.title = name;
        [window center];
        view.wantsLayer = YES;
        view.layer = layer;
        layer.contentsScale = window.backingScaleFactor;
        if (metal) {
            CAMetalLayer *metal_layer = (CAMetalLayer *)layer;
            metal_layer.device = graphics->device;
            metal_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            metal_layer.framebufferOnly = YES;
            metal_layer.drawableSize = CGSizeMake(
                (CGFloat)width * layer.contentsScale,
                (CGFloat)height * layer.contentsScale);
        }
        window.contentView = view;
        [window makeKeyAndOrderFront:nil];
        [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];

        LuceWindow *slot = &graphics->windows[number - 1];
        slot->window = window;
        slot->layer = layer;
        slot->width = width;
        slot->height = height;
        slot->alive = 1;
        *handle = number;
        [view release];
        [name release];
        return luce_yes;
    }
}

int luce_macos_graphics_window_surface(void *opaque, int64_t window, int64_t *surface) {
    if (opaque == NULL || surface == NULL) return luce_no;
    @autoreleasepool {
        LuceGraphics *graphics = opaque;
        LuceWindow *window_slot = luce_window(graphics, window);
        if (window_slot == NULL) return luce_no;
        int64_t number = luce_next_surface(graphics);
        if (number == 0) return luce_exhausted;
        LuceSurface *slot = &graphics->surfaces[number - 1];
        slot->layer = [window_slot->layer retain];
        slot->window = window;
        slot->width = window_slot->width;
        slot->height = window_slot->height;
        slot->alive = 1;
        const int metal = graphics->device != nil && graphics->queue != nil && graphics->pipeline != nil;
        if (!metal) {
            size_t pixels = (size_t)slot->width * (size_t)slot->height;
            if (pixels > 64 * 1024 * 1024 / 4) {
                luce_release_surface(slot);
                return luce_exhausted;
            }
            slot->pixel_bytes = pixels * 4;
            slot->pixels = calloc(1, slot->pixel_bytes);
            if (slot->pixels == NULL) {
                luce_release_surface(slot);
                return luce_exhausted;
            }
        }
        slot->clear[0] = 0.0;
        slot->clear[1] = 0.0;
        slot->clear[2] = 0.0;
        slot->clear[3] = 1.0;
        window_slot->surface_refs += 1;
        *surface = number;
        return luce_yes;
    }
}

int luce_macos_graphics_surface_size(void *opaque, int64_t surface, int64_t axis, int64_t *size) {
    if (opaque == NULL || size == NULL || (axis != 0 && axis != 1)) return luce_no;
    LuceSurface *slot = luce_surface(opaque, surface);
    if (slot == NULL) return luce_no;
    *size = axis == 0 ? slot->width : slot->height;
    return luce_yes;
}

static int luce_color(int64_t red, int64_t green, int64_t blue, int64_t alpha, double *out) {
    if (red < 0 || red > 255 || green < 0 || green > 255 || blue < 0 || blue > 255 || alpha < 0 || alpha > 255) return 0;
    out[0] = (double)red / 255.0;
    out[1] = (double)green / 255.0;
    out[2] = (double)blue / 255.0;
    out[3] = (double)alpha / 255.0;
    return 1;
}

int luce_macos_graphics_surface_clear(void *opaque, int64_t surface, int64_t red, int64_t green, int64_t blue, int64_t alpha) {
    if (opaque == NULL) return luce_no;
    LuceSurface *slot = luce_surface(opaque, surface);
    if (slot == NULL || !luce_color(red, green, blue, alpha, slot->clear)) return luce_no;
    slot->rect_count = 0;
    if (slot->pixels != NULL) {
        uint8_t color[4] = { (uint8_t)red, (uint8_t)green, (uint8_t)blue, (uint8_t)alpha };
        for (size_t offset = 0; offset < slot->pixel_bytes; offset += 4) {
            memcpy(slot->pixels + offset, color, sizeof(color));
        }
    }
    return luce_yes;
}

int luce_macos_graphics_surface_fill_rect(
    void *opaque,
    int64_t surface,
    int64_t x,
    int64_t y,
    int64_t width,
    int64_t height,
    int64_t red,
    int64_t green,
    int64_t blue,
    int64_t alpha
) {
    if (opaque == NULL || width <= 0 || height <= 0) return luce_no;
    LuceSurface *slot = luce_surface(opaque, surface);
    if (slot == NULL) return luce_no;
    if (slot->rect_count == luce_max_rects) return luce_exhausted;
    double color[4];
    if (!luce_color(red, green, blue, alpha, color)) return luce_no;
    LuceRect *rect = &slot->rects[slot->rect_count++];
    rect->x = x;
    rect->y = y;
    rect->width = width;
    rect->height = height;
    for (int index = 0; index < 4; index++) rect->color[index] = (float)color[index];
    if (slot->pixels != NULL) {
        int64_t left = x < 0 ? 0 : x;
        int64_t top = y < 0 ? 0 : y;
        int64_t right = x + width > slot->width ? slot->width : x + width;
        int64_t bottom = y + height > slot->height ? slot->height : y + height;
        if (right > left && bottom > top) {
            for (int64_t row = top; row < bottom; row++) {
                for (int64_t column = left; column < right; column++) {
                    size_t offset = ((size_t)row * (size_t)slot->width + (size_t)column) * 4;
                    slot->pixels[offset + 0] = (uint8_t)red;
                    slot->pixels[offset + 1] = (uint8_t)green;
                    slot->pixels[offset + 2] = (uint8_t)blue;
                    slot->pixels[offset + 3] = (uint8_t)alpha;
                }
            }
        }
    }
    return luce_yes;
}

static void luce_vertex(LuceVertex *vertex, float x, float y, const float color[4]) {
    vertex->position[0] = x;
    vertex->position[1] = y;
    for (int index = 0; index < 4; index++) vertex->color[index] = color[index];
}

int luce_macos_graphics_surface_present(void *opaque, int64_t surface) {
    if (opaque == NULL) return luce_no;
    @autoreleasepool {
        LuceGraphics *graphics = opaque;
        LuceSurface *slot = luce_surface(graphics, surface);
        if (slot == NULL) return luce_no;
        if (slot->pixels != NULL) {
            CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
            CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, slot->pixels, slot->pixel_bytes, NULL);
            CGImageRef image = CGImageCreate(
                (size_t)slot->width,
                (size_t)slot->height,
                8,
                32,
                (size_t)slot->width * 4,
                color_space,
                kCGImageAlphaLast | kCGBitmapByteOrderDefault,
                provider,
                NULL,
                false,
                kCGRenderingIntentDefault);
            if (image == NULL) {
                CGDataProviderRelease(provider);
                CGColorSpaceRelease(color_space);
                return luce_no;
            }
            slot->layer.contents = (id)image;
            [slot->layer setNeedsDisplay];
            CGImageRelease(image);
            CGDataProviderRelease(provider);
            CGColorSpaceRelease(color_space);
            return luce_yes;
        }
        if (graphics->pipeline == nil || graphics->queue == nil) return luce_no;
        id<CAMetalDrawable> drawable = [(CAMetalLayer *)slot->layer nextDrawable];
        if (drawable == nil) return luce_no;
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(
            slot->clear[0], slot->clear[1], slot->clear[2], slot->clear[3]);

        id<MTLCommandBuffer> command = [graphics->queue commandBuffer];
        id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
        [encoder setRenderPipelineState:graphics->pipeline];
        for (size_t index = 0; index < slot->rect_count; index++) {
            const LuceRect *rect = &slot->rects[index];
            float left = (float)(2.0 * (double)rect->x / (double)slot->width - 1.0);
            float right = (float)(2.0 * (double)(rect->x + rect->width) / (double)slot->width - 1.0);
            float top = (float)(1.0 - 2.0 * (double)rect->y / (double)slot->height);
            float bottom = (float)(1.0 - 2.0 * (double)(rect->y + rect->height) / (double)slot->height);
            LuceVertex vertices[6];
            luce_vertex(&vertices[0], left, top, rect->color);
            luce_vertex(&vertices[1], right, top, rect->color);
            luce_vertex(&vertices[2], left, bottom, rect->color);
            luce_vertex(&vertices[3], left, bottom, rect->color);
            luce_vertex(&vertices[4], right, top, rect->color);
            luce_vertex(&vertices[5], right, bottom, rect->color);
            [encoder setVertexBytes:vertices length:sizeof(vertices) atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        }
        [encoder endEncoding];
        [command presentDrawable:drawable];
        [command commit];
        slot->rect_count = 0;
        return luce_yes;
    }
}

int luce_macos_graphics_close(void *opaque, int64_t handle, int64_t kind) {
    if (opaque == NULL) return luce_no;
    @autoreleasepool {
        LuceGraphics *graphics = opaque;
        if (kind == luce_surface_kind) {
            LuceSurface *surface = luce_surface(graphics, handle);
            if (surface == NULL) return luce_no;
            luce_surface_released(graphics, surface);
            return luce_yes;
        }
        if (kind == luce_window_kind) {
            LuceWindow *window = luce_window(graphics, handle);
            if (window == NULL) return luce_no;
            /* Closing a Window value requests that the native window
             * disappear, but derived Surface values retain the host-side
             * object until their own ARC releases. */
            luce_request_window_close(window);
            return luce_yes;
        }
        return luce_no;
    }
}
