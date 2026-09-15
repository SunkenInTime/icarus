#version 460 core
#include <flutter/runtime_effect.glsl>

uniform vec2 uOrigin;
uniform float uSpan;
uniform float uClearance;
uniform float uRange;
uniform vec4 uColor;
uniform float uPixel;
uniform float uResolution;
uniform vec2 uFacing;
uniform float uCosHalfCone;
uniform vec2 uCanvasToMetricX;
uniform vec2 uCanvasToMetricY;
uniform vec2 uMetricToCanvasX;
uniform vec2 uMetricToCanvasY;
uniform float uRadialFalloff;
uniform sampler2D uMask;
out vec4 fragColor;

float visibleAt(vec2 relative) {
  vec2 metric = uCanvasToMetricX * relative.x + uCanvasToMetricY * relative.y;
  float radius = length(metric);
  vec2 direction = radius > 0.0 ? metric / radius : vec2(0.0);
  if (radius > uRange || dot(direction, uFacing) < uCosHalfCone) return 0.0;
  // A wall outside the cone range must not shorten its circular range edge.
  float sampleRadius = min(radius + uClearance, uRange);
  vec2 sampleMetric = direction * sampleRadius;
  vec2 sampleCanvas = uMetricToCanvasX * sampleMetric.x + uMetricToCanvasY * sampleMetric.y;
  vec2 uv = sampleCanvas / uSpan + 0.5;
  // Sample an individual 2x coverage cell, then average the completed result.
  uv = (floor(uv * uResolution) + 0.5) / uResolution;
  return 1.0 - texture(uMask, uv).a;
}

void main() {
  vec2 relative = FlutterFragCoord().xy - uOrigin;
  float quarter = uPixel * 0.25;
  float coverage = (
    visibleAt(relative + vec2(-quarter, -quarter)) +
    visibleAt(relative + vec2( quarter, -quarter)) +
    visibleAt(relative + vec2(-quarter,  quarter)) +
    visibleAt(relative + vec2( quarter,  quarter))) * 0.25;
  vec2 metric = uCanvasToMetricX * relative.x + uCanvasToMetricY * relative.y;
  // The app's RadialGradient(radius: 1) spans the diameter of its R-sized rect.
  float falloff = clamp(1.0 - length(metric) / (2.0 * uRange), 0.0, 1.0);
  float shade = mix(1.0, falloff, uRadialFalloff);
  float alpha = uColor.a * coverage * shade;
  // The existing gradient interpolates toward transparent black.
  fragColor = vec4(uColor.rgb * shade * alpha, alpha);
}
