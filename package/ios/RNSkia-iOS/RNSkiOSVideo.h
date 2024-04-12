#pragma once

#include <string>

#include <CoreVideo/CoreVideo.h>
#include <AVFoundation/AVFoundation.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"

#include "include/core/SkImage.h"

#pragma clang diagnostic pop

#include "RNSkPlatformContext.h"
#include "RNSkVideo.h"

namespace RNSkia {

class RNSkiOSVideo: public RNSkVideo {
private:
    std::string _url;
    AVAssetReader* _reader = nullptr;
    AVAssetReaderTrackOutput* _trackOutput = nullptr;
    RNSkPlatformContext* _context;
public:
    RNSkiOSVideo(std::string url, RNSkPlatformContext* context);
    ~RNSkiOSVideo();
    sk_sp<SkImage> nextImage(double* timeStamp = nullptr) override;
    
    // Utility function to initialize the video reader
    void initializeReader();
};

} // namespace RNSkia