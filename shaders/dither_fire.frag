#version 460 core

// Halftone hero for the update dialog: a grid of round dots whose size and
// color follow layered noise fields, like classic print halftone. Two color
// layers drift through each other — violet "heat" and a cool silver — over a
// near-black background.
//
// uProgress (0..1) energizes the field: at 0 it drifts slowly and dim, at 1
// it brightens and the violet layer dominates. Wire it to download progress.

precision highp float;

#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float uTime;
uniform float uProgress;
uniform float uCell; // dot lattice pitch in logical pixels (e.g. 9)

out vec4 fragColor;

float hash(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

float valueNoise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  float a = hash(i);
  float b = hash(i + vec2(1.0, 0.0));
  float c = hash(i + vec2(0.0, 1.0));
  float d = hash(i + vec2(1.0, 1.0));
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
  float v = 0.0;
  v += 0.50 * valueNoise(p);
  v += 0.25 * valueNoise(p * 2.02 + 19.7);
  v += 0.125 * valueNoise(p * 4.05 + 51.3);
  return v / 0.875;
}

// Violet heat ramp: deep violet -> primary -> lavender -> near-white.
vec3 violetRamp(float t) {
  vec3 c0 = vec3(0.118, 0.039, 0.290); // #1e0a4a-ish deep violet
  vec3 c1 = vec3(0.486, 0.227, 0.929); // #7c3aed primary
  vec3 c2 = vec3(0.769, 0.710, 0.992); // #c4b5fd lavender
  vec3 c3 = vec3(0.961, 0.953, 1.000); // near-white
  if (t < 0.45) return mix(c0, c1, t / 0.45);
  if (t < 0.8) return mix(c1, c2, (t - 0.45) / 0.35);
  return mix(c2, c3, (t - 0.8) / 0.2);
}

// Cool silver ramp for the secondary layer.
vec3 silverRamp(float t) {
  vec3 c0 = vec3(0.145, 0.145, 0.180);
  vec3 c1 = vec3(0.478, 0.478, 0.541);
  vec3 c2 = vec3(0.910, 0.906, 0.949);
  if (t < 0.6) return mix(c0, c1, t / 0.6);
  return mix(c1, c2, (t - 0.6) / 0.4);
}

void main() {
  vec2 frag = FlutterFragCoord().xy;

  // Dot lattice: everything is sampled at the cell center so each dot gets
  // one intensity/color.
  vec2 cellIdx = floor(frag / uCell);
  vec2 center = (cellIdx + 0.5) * uCell;
  vec2 p = center / uSize.y; // aspect-correct field coordinates

  float t = uTime;
  float energy = mix(0.55, 1.0, uProgress);

  // Two independent blob fields drifting in different directions.
  float fieldA = fbm(p * 1.9 + vec2(t * 0.18, -t * 0.38));
  float fieldB = fbm(p * 2.3 + vec2(-t * 0.26, t * 0.15) + 31.0);

  // Slower large-scale mask deciding which layer owns each region.
  float owner = fbm(p * 0.9 + vec2(t * 0.07, t * 0.05) + 77.0);
  // Progress pushes ownership toward the violet layer.
  owner = clamp(owner + (uProgress * 0.35 - 0.05), 0.0, 1.0);

  // Sharpen fields into blobs with breathing room between them.
  float a = smoothstep(0.35, 0.85, fieldA) * energy;
  float b = smoothstep(0.42, 0.88, fieldB) * energy * 0.8;

  float wA = a * owner;
  float wB = b * (1.0 - owner);
  float intensity = max(wA, wB);

  // Gentle global pulse so the field feels alive even when idle.
  intensity *= 0.92 + 0.08 * sin(t * 1.8 + p.x * 4.0 + p.y * 3.0);

  // Dot radius follows intensity; sqrt keeps ink area proportional.
  float radius = 0.62 * uCell * sqrt(clamp(intensity, 0.0, 1.0));
  float d = length(frag - center);
  float dotMask = 1.0 - smoothstep(radius - 0.8, radius + 0.8, d);

  // Color: blend the two ramps by which layer dominates this dot.
  float mixToB = wB / max(wA + wB, 1e-4);
  vec3 color = mix(violetRamp(intensity), silverRamp(intensity), mixToB);

  // Faint background dots keep the lattice visible where blobs are absent.
  float baseDot =
      (1.0 - smoothstep(0.16 * uCell, 0.16 * uCell + 0.8, d)) * 0.10;

  float alpha = clamp(dotMask * (0.35 + 0.65 * intensity) + baseDot, 0.0, 1.0);
  fragColor = vec4(color * alpha, alpha); // premultiplied
}
