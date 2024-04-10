#import <MetalKit/MetalKit.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"

#import "include/core/SkCanvas.h"
#import "include/gpu/GrDirectContext.h"
#import "include/gpu/GrYUVABackendTextures.h"
#import <CoreMedia/CMSampleBuffer.h>
#import <CoreVideo/CVMetalTextureCache.h>
#import <memory>

#pragma clang diagnostic pop

using SkiaMetalContext = struct SkiaMetalContext {
  id<MTLDevice> device = nullptr;
  id<MTLCommandQueue> commandQueue = nullptr;
  sk_sp<GrDirectContext> skContext = nullptr;
};

enum class CVPixelBufferBaseFormat {
  yuv,
  rgb
};

class ThreadContextHolder {
private:
  static thread_local std::unique_ptr<SkiaMetalContext> ThreadSkiaMetalContext;
public:
  static const std::unique_ptr<SkiaMetalContext>& getThreadSpecificSkiaContext();
};

class SkiaMetalSurfaceFactory {
public:
  static sk_sp<SkSurface> makeWindowedSurface(id<MTLTexture> texture, int width,
                                              int height);
  static sk_sp<SkSurface> makeOffscreenSurface(int width, int height);

  static sk_sp<SkImage> makeImageFromCMSampleBuffer(CMSampleBufferRef sampleBuffer);

private:
  static CVMetalTextureCacheRef getTextureCache();

  static GrBackendTexture getTextureFromCVPixelBuffer(CVPixelBufferRef pixelBuffer, size_t planeIndex, MTLPixelFormat pixelFormat);
  static GrYUVABackendTextures getYUVTexturesFromCVPixelBuffer(CVPixelBufferRef pixelBuffer);
  static CVPixelBufferBaseFormat getCVPixelBufferBaseFormat(CVPixelBufferRef pixelBuffer);
  static SkYUVAInfo getYUVAInfoForCVPixelBuffer(CVPixelBufferRef pixelBuffer);
};
