// Library content for the cost scenarios, the same on every run.
//
// Read costs are byte counts of the rows a function reads, so a run is only
// comparable with the last one if it writes rows of the same sizes. Every id
// and number here comes from one seeded generator: the same seed writes the
// same library, and page slices (which split a page by element id) hold the
// same elements every run. Payload shapes are copied from rows the desktop
// app wrote to the dev deployment (element payloads as the Dart models'
// toJson() writes them).

/// A small seeded generator (mulberry32).
export function seeded(seed) {
  let state = seed >>> 0;
  const next = () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  const hex = (count) => {
    let out = "";
    for (let i = 0; i < count; i++) out += Math.floor(next() * 16).toString(16);
    return out;
  };
  return {
    next,
    /// A version-4 UUID, as the app makes for every public id.
    uuid() {
      const variant = "89ab"[Math.floor(next() * 4)];
      return `${hex(8)}-${hex(4)}-4${hex(3)}-${variant}${hex(3)}-${hex(12)}`;
    },
    pick(list) {
      return list[Math.floor(next() * list.length)];
    },
    /// A canvas position, with the many decimals a drag leaves.
    position() {
      return { dx: 200 + next() * 1400, dy: 100 + next() * 800 };
    },
  };
}

const AGENTS = ["astra", "jett", "sova", "omen", "killjoy", "viper", "fade"];

/// An element payload of [kind] with public id [id].
export function elementPayload(kind, id, rng) {
  const position = rng.position();
  switch (kind) {
    case "agent":
      return {
        kind: "agent",
        payloadVersion: 1,
        data: {
          elementType: "agent",
          id,
          isAlly: true,
          isDeleted: false,
          kind: "plain",
          lineUpID: null,
          position,
          state: "none",
          type: rng.pick(AGENTS),
          weapon: "none",
        },
      };
    case "ability":
      return {
        kind: "ability",
        payloadVersion: 1,
        data: {
          armLengthsMeters: [10, 10, 10, 10],
          data: { index: Math.floor(rng.next() * 4), type: rng.pick(AGENTS) },
          elementType: "ability",
          id,
          isAlly: true,
          isDeleted: false,
          length: 0,
          lineUpID: null,
          position,
          rotation: 0,
          visualState: {
            showInnerFill: true,
            showInnerOutline: true,
            showRangeFill: true,
            showRangeOutline: true,
            showVisionCone: true,
          },
        },
      };
    case "utility":
      return {
        kind: "utility",
        payloadVersion: 1,
        data: {
          angle: 0,
          customColorValue: 4289887296,
          customDiameter: null,
          customLength: 1.895722920590427,
          customOpacityPercent: 100,
          customWidth: 0.2875432525951557,
          elementType: "utility",
          id,
          isAlly: true,
          isDeleted: false,
          length: 0,
          mapDoor: null,
          position,
          rotation: 1.5707963267948966,
          type: "customRectangle",
          visionElevation: null,
        },
      };
    case "text":
      return {
        kind: "text",
        payloadVersion: 1,
        data: {
          elementType: "text",
          fontSize: 20,
          id,
          isDeleted: false,
          position,
          size: 260,
          sizeVersion: 1,
          tagColorValue: 4280468830,
          text: "Smoke heaven, then swing\nwith the flash",
        },
      };
    case "drawing": {
      const end = rng.position();
      return {
        kind: "drawing",
        payloadVersion: 1,
        data: {
          boundingBox: {
            max: {
              dx: Math.max(position.dx, end.dx),
              dy: Math.max(position.dy, end.dy),
            },
            min: {
              dx: Math.min(position.dx, end.dx),
              dy: Math.min(position.dy, end.dy),
            },
          },
          colorValue: 4280468830,
          elementType: "drawing",
          hasArrow: true,
          id,
          isDotted: true,
          lineEnd: end,
          lineStart: position,
          showTraversalTime: false,
          thickness: 5,
          traversalSpeedProfile: "running",
          type: "lineDrawing",
        },
      };
    }
    default:
      throw new Error(`No payload for element kind ${kind}`);
  }
}

/// The kinds a page of [count] elements holds, in a mix like real pages:
/// one in five an agent, the rest abilities, utilities, text and drawings.
export function pageKinds(count) {
  const cycle = ["agent", "ability", "ability", "utility", "text", "ability", "drawing", "agent", "ability", "text"];
  return Array.from({ length: count }, (_, i) => cycle[i % cycle.length]);
}

/// element.add ops for a page of [count] elements.
export function elementAdds(pagePublicId, count, rng) {
  return pageKinds(count).map((kind, sortIndex) => {
    const id = rng.uuid();
    return {
      opId: rng.uuid(),
      type: "element.add",
      elementPublicId: id,
      pagePublicId,
      payload: elementPayload(kind, id, rng),
      sortIndex,
    };
  });
}

/// [ops] in batches of at most 40, as the app sends them.
export function batches(ops, size = 40) {
  const out = [];
  for (let i = 0; i < ops.length; i += size) out.push(ops.slice(i, i + size));
  return out;
}

/// Where each slice of a page with about [elementCount] elements starts, as
/// lib/collab/page_slices.dart pageSliceStarts works it out.
export function pageSliceStarts(elementCount) {
  const count =
    elementCount < 16 ? 1 : elementCount < 32 ? 2 : elementCount < 64 ? 4 : elementCount < 128 ? 8 : 16;
  const hexDigits = "0123456789abcdef";
  return Array.from({ length: count }, (_, i) => (i === 0 ? "" : hexDigits[(i * 16) / count]));
}
