#version 460 core

precision highp float;

#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float uTime;
uniform float uCell;
uniform float uRise;
uniform float uPulse;
uniform vec2 uPointer;
uniform float uPointerOn;
uniform vec2 uSurgeAt;
uniform float uSurge;
uniform vec4 uCalm;
uniform vec4 uGround;

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

vec3 violetRamp(float t) {
  vec3 c0 = vec3(0.118, 0.039, 0.290);
  vec3 c1 = vec3(0.486, 0.227, 0.929);
  vec3 c2 = vec3(0.769, 0.710, 0.992);
  vec3 c3 = vec3(0.961, 0.953, 1.000);
  if (t < 0.45) return mix(c0, c1, t / 0.45);
  if (t < 0.8) return mix(c1, c2, (t - 0.45) / 0.35);
  return mix(c2, c3, (t - 0.8) / 0.2);
}

vec3 silverRamp(float t) {
  vec3 c0 = vec3(0.145, 0.145, 0.180);
  vec3 c1 = vec3(0.478, 0.478, 0.541);
  vec3 c2 = vec3(0.910, 0.906, 0.949);
  if (t < 0.6) return mix(c0, c1, t / 0.6);
  return mix(c1, c2, (t - 0.6) / 0.4);
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 cellIdx = floor(frag / uCell);
  vec2 center = (cellIdx + 0.5) * uCell;
  float shortSide = min(uSize.x, uSize.y);
  vec2 p = center / shortSide;
  float t = uTime;

  float R = 1.15 * uSize.x;
  float limbY = uSize.y * (1.04 - 0.43 * uRise);
  vec2 sun = vec2(uSize.x * 0.5, limbY + R);
  vec2 toSun = center - sun;
  float edge = (length(toSun) - R) / shortSide;
  float inside = 1.0 - smoothstep(-0.004, 0.010, edge);
  float outside = 1.0 - inside;

  float wA = 0.0;
  float wB = 0.0;
  float grain = 0.5;

  if (edge < 0.012) {
    vec2 warp = vec2(
      fbm(p * 2.0 + vec2(t * 0.05, 0.0)),
      fbm(p * 2.0 + vec2(7.3, -t * 0.04))
    );
    grain = fbm(p * 4.4 + warp * 1.4 + vec2(0.0, t * 0.07));
    float cells = smoothstep(0.28, 0.78, grain);
    float limbHeat = exp(min(edge, 0.0) / 0.055);
    float depth = smoothstep(0.0, 0.55, -edge);
    float body = (0.24 + 0.36 * cells + 0.62 * limbHeat + uPulse)
        * mix(1.0, 0.62, depth) * inside;
    float coolCells =
        smoothstep(0.56, 0.70, fbm(p * 3.4 + vec2(t * 0.03, t * 0.02) + 77.0))
        * (1.0 - limbHeat) * 0.7;
    wA = body * (1.0 - coolCells);
    wB = body * coolCells * 0.85;
  }

  if (edge > -0.006 && edge < 1.1) {
    float along = atan(toSun.x, -toSun.y);
    float tongue = fbm(vec2(along * 19.0, edge * 2.0 - t * 0.33));
    float fine = fbm(vec2(along * 64.0 + 9.0, edge * 6.0 - t * 0.7));

    vec2 ptrToSun = uPointer - sun;
    float ptrEdge = (length(ptrToSun) - R) / shortSide;
    float ptrAlong = atan(ptrToSun.x, -ptrToSun.y);
    float beside = (along - ptrAlong) * R / shortSide;
    float pull = exp(-beside * beside / 0.014)
        * exp(-max(ptrEdge, 0.0) / 0.22) * uPointerOn;

    float reach = 0.028 + 0.46 * pow(tongue, 2.3) + 0.03 * fine + uPulse * 0.3
        + pull * (0.10 + 0.9 * max(ptrEdge, 0.0)) * (0.75 + 0.5 * fine);
    float corona = pow(clamp(1.0 - edge / reach, 0.0, 1.0), 1.7)
        * (0.55 + 0.45 * fine) * outside;

    float drift = fbm(vec2(
      p.x * 7.5 + 0.12 * sin(t * 0.4 + p.y * 6.0),
      p.y * 5.2 + t * 0.34
    ));
    float ember = smoothstep(0.69, 0.85, drift)
        * exp(-max(edge, 0.0) / 0.15) * outside * 0.66;
    ember *= smoothstep(0.06, 0.14, ember);
    float cooled = smoothstep(0.03, 0.22, edge);

    wA = max(wA, max(corona, ember * (1.0 - cooled)));
    wB = max(wB, ember * cooled);
  }

  wA *= uRise;
  wB *= uRise;

  vec2 q = (center - uCalm.xy) / uCalm.zw;
  float calm = 1.0 - smoothstep(0.55, 1.0, length(q));
  float hush = 1.0 - 0.92 * calm * outside;
  wA *= hush;
  wB *= hush;

  float pd = distance(center, uPointer) / shortSide;
  if (uPointerOn > 0.001 && pd < 0.115) {
    float pool = 1.0 - smoothstep(0.008, 0.115, pd);
    pool *= pool;
    float rim = fbm(p * 5.1 + vec2(t * 0.24, -t * 0.19));
    wA = max(wA, pool * (0.55 + 0.45 * rim) * 0.6 * uPointerOn);
  }

  float sd = distance(center, uSurgeAt) / shortSide;
  float started = step(0.001, uSurge);
  float front = uSurge * 2.3;
  float passed = (1.0 - smoothstep(front - 0.30, front - 0.06, sd)) * started;
  wA *= 1.0 - passed;
  wB *= 1.0 - passed;
  float ring = smoothstep(front - 0.26, front - 0.02, sd)
      * (1.0 - smoothstep(front - 0.02, front + 0.03, sd)) * started;
  wA = max(wA, ring * (0.80 + 0.2 * grain) * (1.0 - 0.75 * uSurge));

  float intensity = max(wA, wB);
  intensity *= 0.94 + 0.06 * sin(t * 1.8 + p.x * 4.0 + p.y * 3.0);

  float radius = 0.62 * uCell * sqrt(clamp(intensity, 0.0, 1.0));
  float d = length(frag - center);
  float dotMask = 1.0 - smoothstep(radius - 0.8, radius + 0.8, d);
  float mixToB = wB / max(wA + wB, 1e-4);
  vec3 color = mix(violetRamp(intensity), silverRamp(intensity), mixToB);
  float baseDot =
      (1.0 - smoothstep(0.16 * uCell, 0.16 * uCell + 0.8, d)) * 0.10
      * (1.0 - passed);
  float alpha = clamp(dotMask * (0.35 + 0.65 * intensity) + baseDot, 0.0, 1.0);

  float ground = uGround.a * (1.0 - passed);
  fragColor = vec4(
    color * alpha + uGround.rgb * ground * (1.0 - alpha),
    alpha + ground * (1.0 - alpha)
  );
}
