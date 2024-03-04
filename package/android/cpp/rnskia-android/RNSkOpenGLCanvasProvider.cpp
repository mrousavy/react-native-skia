#include "RNSkOpenGLCanvasProvider.h"

#include <memory>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"

#include "SkCanvas.h"
#include "SkSurface.h"

#pragma clang diagnostic pop

namespace RNSkia {

RNSkOpenGLCanvasProvider::RNSkOpenGLCanvasProvider(
    std::function<void()> requestRedraw,
    std::shared_ptr<RNSkia::RNSkPlatformContext> platformContext)
    : RNSkCanvasProvider(requestRedraw), _platformContext(platformContext) {}

RNSkOpenGLCanvasProvider::~RNSkOpenGLCanvasProvider() {}

float RNSkOpenGLCanvasProvider::getScaledWidth() {
  return _surfaceHolder ? _surfaceHolder->getWidth() : 0;
}

float RNSkOpenGLCanvasProvider::getScaledHeight() {
  return _surfaceHolder ? _surfaceHolder->getHeight() : 0;
}

bool RNSkOpenGLCanvasProvider::renderToCanvas(
    const std::function<void(SkCanvas *)> &cb) {

  if (_surfaceHolder != nullptr && cb != nullptr) {
    // Get the surface
    auto surface = _surfaceHolder->getSurface();
    if (surface) {

      // Ensure we are ready to render
      if (!_surfaceHolder->makeCurrent()) {
        return false;
      }
      this->updateTexImage();

      // Draw into canvas using callback
      cb(surface->getCanvas());

      // Swap buffers and show on screen
      return _surfaceHolder->present();

    } else {
      // the render context did not provide a surface
      return false;
    }
  }

  return false;
}

void RNSkOpenGLCanvasProvider::updateTexImage() {
  if (_jSurfaceTexture == nullptr || _updateTexImageMethod == nullptr) {
    return;
  }

  JNIEnv *env = facebook::jni::Environment::current();

  // Call updateTexImage on the SurfaceTexture object
  env->CallVoidMethod(_jSurfaceTexture, _updateTexImageMethod);

  // Check for exceptions
  if (env->ExceptionCheck()) {
    RNSkLogger::logToConsole("updateAndRelease() failed. The exception above "
                              "can safely be ignored");
    env->ExceptionClear();
  }
}

void RNSkOpenGLCanvasProvider::surfaceAvailable(jobject surfaceTexture, int width,
                                                int height) {
  JNIEnv *env = facebook::jni::Environment::current();
  _jSurfaceTexture = env->NewGlobalRef(surfaceTexture);
  // Prepare the updateTexImage() method
  jclass surfaceTextureClass = env->GetObjectClass(surfaceTexture);
  _updateTexImageMethod =
      env->GetMethodID(surfaceTextureClass, "updateTexImage", "()V");
  // Create a new Surface instance
  jclass surfaceClass = env->FindClass("android/view/Surface");
  jmethodID surfaceConstructor = env->GetMethodID(
      surfaceClass, "<init>", "(Landroid/graphics/SurfaceTexture;)V");
  jobject surface =
      env->NewObject(surfaceClass, surfaceConstructor, surfaceTexture);

  // Create renderer!
  _surfaceHolder =
      SkiaOpenGLSurfaceFactory::makeWindowedSurface(surface, width, height);

  // delete local references
  env->DeleteLocalRef(surface);
  env->DeleteLocalRef(surfaceTextureClass);

  // Post redraw request to ensure we paint in the next draw cycle.
  _requestRedraw();
}
void RNSkOpenGLCanvasProvider::surfaceDestroyed() {
  // destroy the renderer (a unique pointer so the dtor will be called
  // immediately.)
  _surfaceHolder = nullptr;
  if (_jSurfaceTexture != nullptr) {
    // destroy the SurfaceTexture if we have one
    JNIEnv *env = facebook::jni::Environment::current();
    env->DeleteGlobalRef(_jSurfaceTexture);
  }
}

void RNSkOpenGLCanvasProvider::surfaceSizeChanged(int width, int height) {
  if (width == 0 && height == 0) {
    // Setting width/height to zero is nothing we need to care about when
    // it comes to invalidating the surface.
    return;
  }

  // Recreate RenderContext surface based on size change???
  _surfaceHolder->resize(width, height);

  // Redraw after size change
  _requestRedraw();
}
} // namespace RNSkia
