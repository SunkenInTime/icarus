#version 460 core

// Hover-aware dot grid. Draws the same dot lattice as DotPainter, but with a
// soft gaussian "light" that follows the cursor: dots near it brighten and
// swell slightly, dots elsewhere dim while the hover is active.

precision highp float;

#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;        // widget size in logical pixels
uniform vec2 uMouse;       // eased cursor position, local coordinates
uniform float uHover;      // 0..1 fade of the whole effect (mouse enter/exit)
uniform float uSpacing;    // distance between dot centers
uniform float uDotRadius;  // base dot radius
uniform float uGlowRadius; // sigma of the gaussian falloff around the cursor
uniform vec4 uBaseColor;   // resting dot color (straight alpha)
uniform vec4 uGlowColor;   // dot color at the center of the glow (straight alpha)

out vec4 fragColor;

void main() {
  vec2 p = FlutterFragCoord().xy;

  // Distance from this fragment to the nearest dot center on the lattice.
  vec2 cell = mod(p + uSpacing * 0.5, uSpacing) - uSpacing * 0.5;
  float distToDot = length(cell);

  // Gaussian falloff around the cursor, gated by the hover fade.
  float d = distance(p, uMouse);
  float glow = exp(-(d * d) / (2.0 * uGlowRadius * uGlowRadius)) * uHover;

  // No swell, no field dimming: the glow should read as a faint sheen on the
  // surface, not as an effect. Only the dot color/alpha lifts near the cursor.
  float dotMask =
      1.0 - smoothstep(uDotRadius - 0.75, uDotRadius + 0.75, distToDot);

  float alpha = mix(uBaseColor.a, uGlowColor.a, glow);
  vec3 color = mix(uBaseColor.rgb, uGlowColor.rgb, glow);

  float a = alpha * dotMask;
  fragColor = vec4(color * a, a); // premultiplied alpha
}
