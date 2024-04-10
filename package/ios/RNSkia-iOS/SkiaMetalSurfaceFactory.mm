#import "RNSkLog.h"

#include "SkiaMetalSurfaceFactory.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"

#import "include/core/SkCanvas.h"
#import "include/core/SkColorSpace.h"
#import "include/core/SkSurface.h"

#import <include/gpu/GrBackendSurface.h>
#import <include/gpu/GrDirectContext.h>
#import <include/gpu/ganesh/SkImageGanesh.h>
#import <include/gpu/ganesh/SkSurfaceGanesh.h>
#import <include/gpu/GrYUVABackendTextures.h>
#import <include/core/SkYUVAInfo.h>

#pragma clang diagnostic pop

#include <TargetConditionals.h>
#if TARGET_RT_BIG_ENDIAN
#define FourCC2Str(fourcc)                                                     \
  (const char[]) {                                                             \
    *((char *)&fourcc), *(((char *)&fourcc) + 1), *(((char *)&fourcc) + 2),    \
        *(((char *)&fourcc) + 3), 0                                            \
  }
#else
#define FourCC2Str(fourcc)                                                     \
  (const char[]) {                                                             \
    *(((char *)&fourcc) + 3), *(((char *)&fourcc) + 2),                        \
        *(((char *)&fourcc) + 1), *(((char *)&fourcc) + 0), 0                  \
  }
#endif

thread_local std::unique_ptr<SkiaMetalContext> ThreadContextHolder::ThreadSkiaMetalContext = std::make_unique<SkiaMetalContext>();

const std::unique_ptr<SkiaMetalContext>& ThreadContextHolder::getThreadSpecificSkiaContext() {
  const std::unique_ptr<SkiaMetalContext>& context = ThreadContextHolder::ThreadSkiaMetalContext;
  if (context->skContext == nullptr) {
    context->device = MTLCreateSystemDefaultDevice();
    context->commandQueue =
        id<MTLCommandQueue>(CFRetain((GrMTLHandle)[context->device newCommandQueue]));
    context->skContext = GrDirectContext::MakeMetal(
        (__bridge void *)context->device,
        (__bridge void *)context->commandQueue);
    if (context->skContext == nullptr) {
      throw std::runtime_error("Failed to create thread-specific Skia context!");
    }
  }
  return context;
}

struct OffscreenRenderContext {
  id<MTLTexture> texture;

  OffscreenRenderContext(id<MTLDevice> device,
                         sk_sp<GrDirectContext> skiaContext,
                         id<MTLCommandQueue> commandQueue, int width,
                         int height) {
    // Create a Metal texture descriptor
    MTLTextureDescriptor *textureDescriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:width
                                    height:height
                                 mipmapped:NO];
    textureDescriptor.usage =
        MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    texture = [device newTextureWithDescriptor:textureDescriptor];
  }
};


sk_sp<SkSurface>
SkiaMetalSurfaceFactory::makeWindowedSurface(id<MTLTexture> texture, int width,
                                             int height) {
  // Ensure Skia context is available
  const auto& context = ThreadContextHolder::getThreadSpecificSkiaContext();
  GrMtlTextureInfo fbInfo;
  fbInfo.fTexture.retain((__bridge void *)texture);

  GrBackendRenderTarget backendRT(width, height, fbInfo);

  auto skSurface = SkSurfaces::WrapBackendRenderTarget(context->skContext.get(), backendRT,
      kTopLeft_GrSurfaceOrigin, kBGRA_8888_SkColorType, nullptr, nullptr);

  if (skSurface == nullptr || skSurface->getCanvas() == nullptr) {
    RNSkia::RNSkLogger::logToConsole(
        "Skia surface could not be created from parameters.");
    return nullptr;
  }
  return skSurface;
}

sk_sp<SkSurface> SkiaMetalSurfaceFactory::makeOffscreenSurface(int width,
                                                               int height) {
  const auto& context = ThreadContextHolder::getThreadSpecificSkiaContext();
  auto ctx = new OffscreenRenderContext(context->device, context->skContext, context->commandQueue, width, height);

  // Create a GrBackendTexture from the Metal texture
  GrMtlTextureInfo info;
  info.fTexture.retain((__bridge void *)ctx->texture);
  GrBackendTexture backendTexture(width, height, skgpu::Mipmapped::kNo, info);

  // Create a SkSurface from the GrBackendTexture
  auto surface = SkSurfaces::WrapBackendTexture(context->skContext.get(),
      backendTexture, kTopLeft_GrSurfaceOrigin, 0, kBGRA_8888_SkColorType,
      nullptr, nullptr,
      [](void *addr) { delete (OffscreenRenderContext *)addr; }, ctx);

  return surface;
}

CVMetalTextureCacheRef SkiaMetalSurfaceFactory::getTextureCache() {

  static thread_local CVMetalTextureCacheRef textureCache = nil;
  static thread_local size_t accessCounter = 0;
  if (textureCache == nil) {
    // Create a new Texture Cache
    const auto& context = ThreadContextHolder::getThreadSpecificSkiaContext();
    auto result = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, context->device,
                                            nil, &textureCache);
    if (result != kCVReturnSuccess || textureCache == nil) {
      throw std::runtime_error("Failed to create Metal Texture Cache!");
    }
  }
  accessCounter++;
  if (accessCounter > 15) {
    // Every 5 accesses, we perform some internal recycling/housekeeping
    // operations.
    CVMetalTextureCacheFlush(textureCache, 0);
    accessCounter = 0;
  }
  return textureCache;
}

GrBackendTexture SkiaMetalSurfaceFactory::getTextureFromCVPixelBuffer(CVPixelBufferRef pixelBuffer, size_t planeIndex, MTLPixelFormat pixelFormat) {
  // 1. Get cache
  CVMetalTextureCacheRef textureCache = getTextureCache();

  // 2. Get MetalTexture from CMSampleBuffer
  CVMetalTextureRef textureHolder;
  size_t width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex);
  size_t height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex);
  CVReturn result = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                                                              pixelFormat, width, height, planeIndex, &textureHolder);
  if (result != kCVReturnSuccess) {
    throw std::runtime_error("Failed to create Metal Texture from CMSampleBuffer! Result: " +
                             std::to_string(result));
  }

  // 2. Unwrap the underlying MTLTexture
  id<MTLTexture> mtlTexture = CVMetalTextureGetTexture(textureHolder);
  if (mtlTexture == nil) {
    throw std::runtime_error("Failed to get MTLTexture from CVMetalTextureRef!");
  }

  // 3. Wrap MTLTexture in Skia's GrBackendTexture
  GrMtlTextureInfo textureInfo;
  textureInfo.fTexture.retain((__bridge void *)mtlTexture);
  GrBackendTexture texture = GrBackendTexture((int)mtlTexture.width, (int)mtlTexture.height,
                                  skgpu::Mipmapped::kNo, textureInfo);
  CFRelease(textureHolder);
  return texture;
}

SkYUVAInfo::PlaneConfig getPlaneConfig(OSType pixelFormat) {
  switch (pixelFormat) {
    case kCVPixelFormatType_420YpCbCr8Planar:
    case kCVPixelFormatType_420YpCbCr8PlanarFullRange:
      return SkYUVAInfo::PlaneConfig::kYUV;
    case kCVPixelFormatType_422YpCbCr_4A_8BiPlanar:
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
    case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_422YpCbCr8BiPlanarFullRange:
    case kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
    case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange:
    case kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:
    case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
    case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
    case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
    case kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange:
    case kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange:
      return SkYUVAInfo::PlaneConfig::kY_UV;
    case kCVPixelFormatType_420YpCbCr8VideoRange_8A_TriPlanar:
    case kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar:
      return SkYUVAInfo::PlaneConfig::kY_U_V;
    default:
      throw std::runtime_error("Invalid pixel format! " + std::string(FourCC2Str(pixelFormat)));
  }
}
SkYUVAInfo::Subsampling getSubsampling(OSType pixelFormat) {
  switch (pixelFormat) {
    case kCVPixelFormatType_420YpCbCr8Planar:
    case kCVPixelFormatType_420YpCbCr8PlanarFullRange:
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
    case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
    case kCVPixelFormatType_420YpCbCr8VideoRange_8A_TriPlanar:
      return SkYUVAInfo::Subsampling::k420;
    case kCVPixelFormatType_4444YpCbCrA8:
    case kCVPixelFormatType_4444YpCbCrA8R:
    case kCVPixelFormatType_4444AYpCbCr8:
    case kCVPixelFormatType_4444AYpCbCr16:
    case kCVPixelFormatType_4444AYpCbCrFloat:
    case kCVPixelFormatType_444YpCbCr8:
    case kCVPixelFormatType_444YpCbCr10:
    case kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
    case kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:
    case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
    case kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange:
    case kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar:
      return SkYUVAInfo::Subsampling::k444;
    case kCVPixelFormatType_422YpCbCr8:
    case kCVPixelFormatType_422YpCbCr16:
    case kCVPixelFormatType_422YpCbCr10:
    case kCVPixelFormatType_422YpCbCr_4A_8BiPlanar:
    case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_422YpCbCr8BiPlanarFullRange:
    case kCVPixelFormatType_422YpCbCr8_yuvs:
    case kCVPixelFormatType_422YpCbCr8FullRange:
    case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange:
    case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
    case kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange:
      return SkYUVAInfo::Subsampling::k422;
    default:
      throw std::runtime_error("Invalid pixel format! " + std::string(FourCC2Str(pixelFormat)));
  }
}
SkYUVColorSpace getColorspace(OSType pixelFormat) {
  switch (pixelFormat) {
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
    case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange:
    case kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:
    case kCVPixelFormatType_420YpCbCr8VideoRange_8A_TriPlanar:
    case kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange:
    case kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange:
    case kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar:
      return SkYUVColorSpace::kRec709_Limited_SkYUVColorSpace;
    case kCVPixelFormatType_420YpCbCr8PlanarFullRange:
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
    case kCVPixelFormatType_422YpCbCr8BiPlanarFullRange:
    case kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
    case kCVPixelFormatType_422YpCbCr8FullRange:
    case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
    case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
    case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
      return SkYUVColorSpace::kRec709_Full_SkYUVColorSpace;
    default:
      throw std::runtime_error("Invalid pixel format! " + std::string(FourCC2Str(pixelFormat)));
  }
}

SkYUVAInfo SkiaMetalSurfaceFactory::getYUVAInfoForCVPixelBuffer(CVPixelBufferRef pixelBuffer) {
  SkISize size = SkISize::Make(CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer));
  OSType format = CVPixelBufferGetPixelFormatType(pixelBuffer);
  SkYUVAInfo::PlaneConfig planeConfig = getPlaneConfig(format);
  SkYUVAInfo::Subsampling subsampling = getSubsampling(format);
  SkYUVColorSpace colorspace = getColorspace(format);
  return SkYUVAInfo(size, planeConfig, subsampling, colorspace);
}
MTLPixelFormat getMTLPixelFormatForCVPixelBufferPlane(CVPixelBufferRef pixelBuffer, size_t planeIndex) {
  size_t width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex);
  size_t bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, planeIndex);
  double bytesPerPixel = round(static_cast<double>(bytesPerRow) / width);
  if (bytesPerPixel == 1) {
    return MTLPixelFormatR8Unorm;
  } else if (bytesPerPixel == 2) {
    return MTLPixelFormatRG8Unorm;
  } else if (bytesPerPixel == 4) {
    return MTLPixelFormatRGBA8Unorm;
  } else {
    throw std::runtime_error("Invalid bytes per row! Expected 1 (R), 2 (RG) or 4 (RGBA), but received " + std::to_string(bytesPerPixel));
  }
}

GrYUVABackendTextures SkiaMetalSurfaceFactory::getYUVTexturesFromCVPixelBuffer(CVPixelBufferRef pixelBuffer) {
  // 1. Get all planes (YUV, Y_UV, Y_U_V or Y_U_V_A)
  size_t planesCount = CVPixelBufferGetPlaneCount(pixelBuffer);
  GrBackendTexture textures[SkYUVAInfo::kMaxPlanes];

  for (size_t planeIndex = 0; planeIndex < planesCount; planeIndex++) {
    MTLPixelFormat pixelFormat = getMTLPixelFormatForCVPixelBufferPlane(pixelBuffer, planeIndex);
    GrBackendTexture texture = getTextureFromCVPixelBuffer(pixelBuffer, planeIndex, pixelFormat);
    textures[planeIndex] = texture;
  }

  // 2. Wrap info about buffer
  SkYUVAInfo info = getYUVAInfoForCVPixelBuffer(pixelBuffer);

  // 3. Return all textures
  return GrYUVABackendTextures(info, textures, kTopLeft_GrSurfaceOrigin);
}

CVPixelBufferBaseFormat SkiaMetalSurfaceFactory::getCVPixelBufferBaseFormat(CVPixelBufferRef pixelBuffer) {
  OSType format = CVPixelBufferGetPixelFormatType(pixelBuffer);
  switch (format) {
    // 8-bit YUV formats
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
    case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_422YpCbCr8BiPlanarFullRange:
    case kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
    // 10-bit YUV formats
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
    case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange:
    case kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:
    case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
    case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
    case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
      return CVPixelBufferBaseFormat::yuv;
    case kCVPixelFormatType_24RGB:
    case kCVPixelFormatType_24BGR:
    case kCVPixelFormatType_32ARGB:
    case kCVPixelFormatType_32BGRA:
    case kCVPixelFormatType_32ABGR:
    case kCVPixelFormatType_32RGBA:
    case kCVPixelFormatType_64ARGB:
    case kCVPixelFormatType_64RGBALE:
    case kCVPixelFormatType_48RGB:
    case kCVPixelFormatType_30RGB:
      return CVPixelBufferBaseFormat::rgb;
    default:
      throw std::runtime_error("Invalid CVPixelBuffer format! " + std::string(FourCC2Str(format)));
  }
}

sk_sp<SkImage> SkiaMetalSurfaceFactory::makeImageFromCMSampleBuffer(
    CMSampleBufferRef sampleBuffer) {
  const auto& context = ThreadContextHolder::getThreadSpecificSkiaContext();

  if (!CMSampleBufferIsValid(sampleBuffer)) {
    throw std::runtime_error("The given CMSampleBuffer is not valid!");
  }

  CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
  double width = CVPixelBufferGetWidth(pixelBuffer);
  double height = CVPixelBufferGetHeight(pixelBuffer);

  // Make sure the format is RGB (BGRA_8888)
  CVPixelBufferBaseFormat baseFormat = getCVPixelBufferBaseFormat(pixelBuffer);
  switch (baseFormat) {
    case CVPixelBufferBaseFormat::rgb: {
      // It's in RGB (BGRA_32), single plane
      GrBackendTexture backendTexture = getTextureFromCVPixelBuffer(pixelBuffer, /*planeIndex */ 0, MTLPixelFormatBGRA8Unorm);
      auto image = SkImages::AdoptTextureFrom(context->skContext.get(), backendTexture, kTopLeft_GrSurfaceOrigin,
                                              kBGRA_8888_SkColorType, kOpaque_SkAlphaType);
      return image;
    }
    case CVPixelBufferBaseFormat::yuv: {
      // It's in YUV, multi-plane
      GrYUVABackendTextures textures = getYUVTexturesFromCVPixelBuffer(pixelBuffer);

      auto image = SkImages::TextureFromYUVATextures(context->skContext.get(), textures, nullptr, [](void* context) {
        // TODO:
      }, nullptr);
      return image;
    }
    default: {
      throw std::runtime_error("Unknown PixelBuffer format!");
    }
  }
}
