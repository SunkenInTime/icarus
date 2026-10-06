#version 460 core

// The background dot grid, as DotPainter lays it out: a lattice whose
// spacing is stretched so the outer dots sit on the edges. One shader over
// one rectangle instead of one point per dot, because the web redraws every
// point of the grid on every frame.

precision highp float;

#include <flutter/runtime_effect.glsl>

uniform vec2 uSpacing;  // distance between dot centres on each axis
uniform vec2 uLast;     // index of the last dot on each axis
uniform float uRadius;  // dot radius
uniform float uPixel;   // one device pixel, in the same units
uniform vec4 uColor;    // dot colour (straight alpha)

out vec4 fragColor;

void main() {
  vec2 p = FlutterFragCoord().xy;

  // The nearest dot that exists: the lattice stops at the edges.
  vec2 index = clamp(floor(p / uSpacing + 0.5), vec2(0.0), uLast);
  float distToDot = length(p - index * uSpacing);

  // About one device pixel of antialiasing at any zoom.
  float mask = clamp((uRadius - distToDot) / uPixel + 0.5, 0.0, 1.0);

  float a = uColor.a * mask;
  fragColor = vec4(uColor.rgb * a, a);  // premultiplied alpha
}
