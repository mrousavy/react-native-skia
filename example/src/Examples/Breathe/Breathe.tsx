import React, { useEffect, useState } from "react";
import { Dimensions } from "react-native";
import type { SkImage } from "@shopify/react-native-skia";
import {
  Canvas,
  Skia,
  ImageShader,
  Shader,
  Fill,
  Image,
  SkSurface,
} from "@shopify/react-native-skia";
import {
  useFrameCallback,
  useSharedValue,
} from "@shopify/react-native-skia/src/external/reanimated/moduleWrapper";
import type { Video } from "@shopify/react-native-skia/src/skia/types/Video";
import { useAssets } from "expo-asset";

const { width, height } = Dimensions.get("window");

const useVideo = (_uri: string) => {
  const [assets, error] = useAssets([require("./sample.mp4")]);
  const [video, setVideo] = useState<Video | null>(null);
  useEffect(() => {
    if (assets === undefined) {
      return;
    }
    const asset = assets[0];
    const v = Skia.Video(asset.localUri!);
    setVideo(v);
  }, [assets]);
  return video;
};

const source = Skia.RuntimeEffect.Make(`
uniform shader image;


half4 main(vec2 fragcoord) {
  return image.eval(fragcoord);

  float2 iResolution = vec2(${width}.0, ${height}.0);
  float2 uv = fragcoord / iResolution;

  float y = uv.y * 3.0;
  half4 c = image.eval(vec2(uv.x, mod(y, 1.0)) * vec2(400.0, 640.0)).bgra;
  return vec4(
    c.r * step(2.0, y) * step(y, 3.0),
    c.g * step(1.0, y) * step(y, 2.0),
    c.b * step(0.0, y) * step(y, 1.0),
    1.0);
}
`)!;

export const Breathe = () => {
  const lastTimestamp = useSharedValue<number>(0);
  const image = useSharedValue<SkImage | null>(null);
  const surface = useSharedValue<SkSurface | null>(null);
  const video = useVideo(require("./sample.mp4"));

  useFrameCallback(({ timestamp }) => {
    if (video === null) {
      return;
    }
    if (surface.value == null) {
      // create an offscreen surface that we will render into
      surface.value = Skia.Surface.MakeOffscreen(width, height)
    }
    if (timestamp - lastTimestamp.value > 16) {
      // throttle to 60 FPS
      lastTimestamp.value = timestamp;

      const canvas = surface.value!.getCanvas()

      // clear the existing canvas
      const red = Skia.Color("red")
      canvas.clear(red)

      // render the next frame from the video
      const frame = video.nextImage(timestamp);
      canvas.drawImage(frame, -450, 100)

      // draw to offscreen and capture result as a texture ("image")
      surface.value!.flush()
      const snapshot = surface.value!.makeImageSnapshot()
      frame.dispose()

      // set the last rendered result to the shared value so RNSkia can render it
      const lastImage = image.value
      image.value = snapshot
      lastImage?.dispose()
    } else {
      console.log("skipping render")
    }
  });
  return (
    <Canvas style={{ flex: 1 }}>
      <Image image={image} x={0} y={0} width={width} height={height} fit="cover" />
    </Canvas>
  );
};
