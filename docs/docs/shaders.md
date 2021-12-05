---
id: shaders
title: Shaders
sidebar_label: Shaders
slug: /shaders
---

Below are some of the shaders available.

## Image

Returns an image as a shader with the specified tiling.
It will use cubic sampling.

```tsx twoslash
import React from "react";
import {
  Canvas,
  Paint,
  Circle,
  ImageShader,
  Skia,
  Shader,
} from "@shopify/react-native-skia";

export const ImageShaderDemo = () => {
  return (
    <Canvas style={{ flex: 1 }}>
      <Paint>
        <ImageShader
          source={require("../../assets/oslo.jpg")}
          fit="cover"
          fitRect={{ x: 0, y: 0, width: 100, height: 100 }}
        />
      </Paint>
      <Circle cx={50} cy={50} r={50} />
    </Canvas>
  );
};
```

## Linear Gradient

## Radial Gradient

## Two Point Conical Gradient

## Sweep Gradient

## Blend Shader

## Color Shader

## Fractal Perlin Noise Shader

## Turbulence Perlin Noise Shader