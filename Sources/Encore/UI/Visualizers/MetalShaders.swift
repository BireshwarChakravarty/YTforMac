// Metal Shading Language source for Encore's GPU visualiser scenes.
//
// Compiled at runtime with `MTLDevice.makeLibrary(source:options:)`, so the
// app needs no precompiled .metallib and builds with plain `swift build`.
// Every scene reads the same uniforms: smoothed loudness bands, a 64-bin
// spectrum texture and a 64×64 spectrum-history texture (newest row first).

enum MetalShaders {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 res;
    float time;
    float bass;
    float mid;
    float treble;
    float level;
    float phase;
    float scroll;
    float dpr;
    float pad0;
    float pad1;
    float4 p0;
    float4 p1;
    float4 p2;
    float4 shadow;
};

constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);

static float hash1(float n) { return fract(sin(n) * 43758.5453123); }
static float hash2(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
static float noise2(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash2(i), hash2(i + float2(1, 0)), u.x),
               mix(hash2(i + float2(0, 1)), hash2(i + float2(1, 1)), u.x), u.y);
}
static float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    float2x2 m = float2x2(float2(1.6, -1.2), float2(1.2, 1.6));
    for (int i = 0; i < 5; i++) { v += a * noise2(p); p = m * p; a *= 0.5; }
    return v;
}
static float3 pal(constant Uniforms &u, float t) {
    t = fract(t);
    float s = t * 3.0;
    if (s < 1.0) return mix(u.p0.rgb, u.p1.rgb, s);
    if (s < 2.0) return mix(u.p1.rgb, u.p2.rgb, s - 1.0);
    return mix(u.p2.rgb, u.p0.rgb, s - 2.0);
}
static float spec(texture2d<float> t, float x) {
    return t.sample(linearSampler, float2(clamp(x, 0.0, 1.0) * 0.92 + 0.02, 0.5)).r;
}
static float3 tonemap(float3 c) { c = max(c, 0.0); return c / (1.0 + c * 0.55); }
static float2 fragCoord(float4 pos, constant Uniforms &u) { return float2(pos.x, u.res.y - pos.y); }

// ---------------------------------------------------------------- quad

struct QuadOut { float4 position [[position]]; };

vertex QuadOut quadVertex(uint vid [[vertex_id]]) {
    const float2 P[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    QuadOut o;
    o.position = float4(P[vid], 0, 1);
    return o;
}

// ---------------------------------------------------------------- 1. Voxels
// Extruded block terrain built from the spectrum history, flowing away.

constant float VOX_HALF = 40.0;
constant float VOX_DEPTH = 64.0;

static float voxelHeight(texture2d<float> hist, float2 c) {
    float fx = abs(c.x + 0.5) / VOX_HALF;
    if (fx > 1.0 || c.y >= VOX_DEPTH) return 0.0;
    float v = hist.sample(linearSampler, float2(fx * 0.8 + 0.03, (max(c.y, 0.0) + 0.5) / VOX_DEPTH)).r;
    float h = 0.3 + pow(v, 1.5) * 11.0 * (1.0 - 0.4 * fx) + noise2(c * 0.31) * 0.9;
    return floor(h * 2.0) / 2.0;
}

fragment float4 voxelFragment(QuadOut in [[stage_in]],
                              constant Uniforms &u [[buffer(0)]],
                              texture2d<float> specTex [[texture(0)]],
                              texture2d<float> hist [[texture(1)]]) {
    float2 uv = (fragCoord(in.position, u) - 0.5 * u.res) / u.res.y;
    float3 ro = float3(sin(u.time * 0.11) * 4.0, 17.0 + u.bass * 0.8, -12.0 - u.scroll);
    float3 fw = normalize(float3(0.0, -0.72, 1.0));
    float3 rt = normalize(cross(float3(0, 1, 0), fw));
    float3 up = cross(fw, rt);
    float3 rd = normalize(fw * 1.05 + rt * uv.x + up * uv.y);

    float3 sky = mix(u.shadow.rgb * 0.6, u.p2.rgb * 0.35, smoothstep(-0.3, 0.6, uv.y))
               + u.p1.rgb * 0.25 * exp(-abs(uv.y - 0.32) * 7.0) * (0.6 + u.level);
    float3 col = sky;

    float2 cell = floor(ro.xz);
    float2 st = sign(rd.xz);
    float2 dl = abs(1.0 / rd.xz);
    float2 tm = (st * (cell - ro.xz) + st * 0.5 + 0.5) * dl;
    float t = 0.0;
    float3 n = float3(0, 1, 0);
    bool hit = false;
    float h = 0.0;
    for (int i = 0; i < 200; i++) {
        h = voxelHeight(hist, cell);
        float tn = min(tm.x, tm.y);
        if (ro.y + rd.y * t < h && t > 0.0) { hit = true; break; }
        if (ro.y + rd.y * tn < h) { t = (h - ro.y) / rd.y; n = float3(0, 1, 0); hit = true; break; }
        if (tm.x < tm.y) { t = tm.x; tm.x += dl.x; cell.x += st.x; n = float3(-st.x, 0, 0); }
        else { t = tm.y; tm.y += dl.y; cell.y += st.y; n = float3(0, 0, -st.y); }
        if (t > 140.0) break;
    }
    if (hit) {
        float3 p = ro + rd * t;
        float fx = abs(cell.x + 0.5) / VOX_HALF;
        float e = clamp(h / 8.0, 0.0, 1.0);
        float3 base = mix(u.shadow.rgb * 2.0 + pal(u, 0.7 + fx * 0.2) * 0.1, pal(u, 0.05 + e * 0.75 + fx * 0.15), smoothstep(0.04, 0.6, e));
        float3 L = normalize(float3(-0.5, 0.9, -0.35));
        float diff = 0.35 + 0.65 * max(dot(n, L), 0.0);
        float2 f = n.y > 0.5 ? fract(p.xz) : float2(n.x != 0.0 ? fract(p.z) : fract(p.x), fract(p.y * 2.0));
        float edge = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y));
        float bevel = smoothstep(0.0, 0.07, edge);
        col = base * diff * (0.55 + 0.45 * bevel);
        col += pal(u, 0.1 + e * 0.8) * pow(e, 2.2) * (1.4 + u.bass * 2.0) * (n.y > 0.5 ? 1.0 : 0.45);
        col += (1.0 - bevel) * pal(u, e) * 0.25 * e;
        float fog = 1.0 - exp(-t * 0.014);
        col = mix(col, sky, fog);
    }
    col *= 1.0 - 0.35 * dot(uv, uv);
    return float4(tonemap(col * 1.15), 1.0);
}

// ---------------------------------------------------------------- 2. Warp
// A tunnel of light panels lit by the spectrum; it speeds up with the bass.

fragment float4 warpFragment(QuadOut in [[stage_in]],
                             constant Uniforms &u [[buffer(0)]],
                             texture2d<float> specTex [[texture(0)]],
                             texture2d<float> hist [[texture(1)]]) {
    float2 p = (fragCoord(in.position, u) - 0.5 * u.res) / u.res.y;
    p += float2(sin(u.time * 0.3), cos(u.time * 0.23)) * 0.04;
    float r = length(p), a = atan2(p.y, p.x);
    float seg = a / (2.0 * M_PI_F) + 0.5;
    float z = 0.42 / max(r, 1e-3) + u.phase * 5.0;
    float cells = 48.0;
    float2 g = float2(seg * cells, z * 1.6);
    float2 id = floor(g), f = fract(g);
    float band = spec(specTex, abs(fract(id.x / cells + 0.25) * 2.0 - 1.0));
    float hz = hash2(id);
    float lit = smoothstep(0.55 - band * 0.8, 1.0, hz + band * 0.6);
    float panel = smoothstep(0.0, 0.08, min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y)));
    float3 c = pal(u, id.x / cells + z * 0.015) * lit * panel * (0.35 + band * 2.4);
    float streak = pow(max(0.0, 1.0 - abs(f.x - 0.5) * 6.0), 2.0)
                 * smoothstep(0.86, 1.0, fract(z * 0.35 + hz * 7.0)) * step(0.6, hz);
    c += float3(1.0) * streak * (0.6 + u.treble * 2.0);
    c *= smoothstep(0.02, 0.35, r);
    c += pal(u, u.phase * 0.05) * (0.25 + u.bass * 1.2) * exp(-r * 9.0) + float3(1.0) * exp(-r * 40.0) * (0.4 + u.bass);
    c *= smoothstep(1.25, 0.25, r) * 0.9 + 0.1;
    return float4(tonemap(c * 1.2), 1.0);
}

// ---------------------------------------------------------------- 3. Vortex
// A swirling storm around a calm eye; the arms tighten with the bass.

fragment float4 vortexFragment(QuadOut in [[stage_in]],
                               constant Uniforms &u [[buffer(0)]],
                               texture2d<float> specTex [[texture(0)]],
                               texture2d<float> hist [[texture(1)]]) {
    float2 p = (fragCoord(in.position, u) - 0.5 * u.res) / u.res.y;
    float r = length(p), a = atan2(p.y, p.x);
    float twist = (0.9 + u.bass * 1.6) / (r + 0.18);
    float sw = a + twist + u.time * 0.25;
    float2 q = float2(cos(sw), sin(sw)) * (r * 2.6 + 0.4);
    float n = fbm(q * 1.4 + float2(u.time * 0.12, -u.time * 0.07));
    float n2 = fbm(q * 3.1 - float2(u.time * 0.2, 0.0) + n * 2.0);
    float arms = pow(0.5 + 0.5 * sin(sw * 3.0 + n * 5.0 - log(r + 0.01) * 4.0), 3.0);
    float band = spec(specTex, fract(a / (2.0 * M_PI_F) + 0.5 + u.time * 0.02) * 0.9);
    float3 c = mix(u.shadow.rgb * 1.2, pal(u, n * 0.8 + r * 0.4 + u.phase * 0.03), smoothstep(0.25, 0.85, n2));
    c *= 0.25 + arms * (1.2 + band * 2.2);
    c += pal(u, 0.6 + n) * pow(n2, 4.0) * 1.8 * (0.5 + u.mid);
    float eye = 0.075 + u.bass * 0.05;
    c *= smoothstep(eye * 0.6, eye * 1.8, r);
    c += pal(u, u.phase * 0.04 + 0.3) * exp(-abs(r - eye * 1.5) * 38.0) * (0.8 + u.level * 2.0);
    c *= smoothstep(1.3, 0.2, r);
    return float4(tonemap(c * 1.25), 1.0);
}

// ---------------------------------------------------------------- 4. Contours
// A living topographic map; loud passages push new peaks up from the centre.

fragment float4 contourFragment(QuadOut in [[stage_in]],
                                constant Uniforms &u [[buffer(0)]],
                                texture2d<float> specTex [[texture(0)]],
                                texture2d<float> hist [[texture(1)]]) {
    float2 p = (fragCoord(in.position, u) - 0.5 * u.res) / u.res.y;
    float r = length(p), a = atan2(p.y, p.x);
    float2 q = p * 2.4;
    float warp = fbm(q * 0.7 + float2(u.time * 0.03, -u.time * 0.02));
    float h = fbm(q + warp * 1.6 + float2(0.0, u.time * 0.04));
    h += (u.bass * 0.55 + 0.1) * exp(-r * r * 4.0);
    h += spec(specTex, fract(a / (2.0 * M_PI_F) + 0.5)) * 0.12 * exp(-r * 2.5);
    float k = h * 16.0;
    float fwk = fwidth(k);
    float d = 0.5 - abs(fract(k) - 0.5);
    float dM = (0.5 - abs(fract(k / 5.0) - 0.5)) * 5.0;
    float line = 1.0 - smoothstep(fwk * 0.4, fwk * 1.4, d);
    float major = 1.0 - smoothstep(fwk * 0.7, fwk * 2.2, dM);
    float3 fill = mix(u.shadow.rgb * 0.9, pal(u, h * 0.9 + 0.1) * 0.22, smoothstep(0.2, 0.9, h));
    float3 ink = pal(u, h * 1.1 + u.phase * 0.02);
    float3 c = fill + ink * line * (0.55 + u.level * 0.9) + ink * major * 0.9;
    c += ink * 0.35 * exp(-r * 3.0) * u.bass;
    c *= 1.0 - 0.45 * dot(p, p);
    return float4(tonemap(c * 1.1), 1.0);
}

// ---------------------------------------------------------------- 5. Tide
// A holographic point-cloud sea: rows carry the recent past, columns the frequencies.

constant float TIDE_COLS = 180.0;
constant float TIDE_ROWS = 90.0;

struct TideOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float3 color;
    float alpha;
};

vertex TideOut tideVertex(uint vid [[vertex_id]],
                          constant Uniforms &u [[buffer(0)]],
                          texture2d<float> hist [[texture(1)]]) {
    float i = float(vid);
    float cx = i - TIDE_COLS * floor(i / TIDE_COLS);
    float cz = floor(i / TIDE_COLS);
    float uu = cx / (TIDE_COLS - 1.0);
    float w = (cz + u.scroll) / TIDE_ROWS;
    float fx = abs(uu * 2.0 - 1.0);
    float v = hist.sample(linearSampler, float2(fx * 0.8 + 0.03, clamp(w, 0.0, 1.0)), level(0)).r;
    float x = (uu - 0.5) * 34.0;
    float z = w * 60.0 + 3.0;
    float y = sin(x * 0.35 + u.time * 0.9 + z * 0.12) * 0.6 + sin(z * 0.25 - u.time * 0.7) * 0.5;
    y += v * v * 7.0 * (1.0 - fx * 0.5);
    float3 pw = float3(x, y, z) - float3(0.0, 6.5, -2.0);
    float pitch = 0.42, cp = cos(pitch), sp = sin(pitch);
    float3 pc = float3(pw.x, pw.y * cp + pw.z * sp, -pw.y * sp + pw.z * cp);
    float f = 1.3;
    TideOut o;
    o.position = float4(pc.x * f / (u.res.x / u.res.y), pc.y * f, pc.z * 0.01, pc.z);
    float depth = clamp(1.0 - w, 0.0, 1.0);
    o.pointSize = max(1.0, (1.2 + v * 2.5) * u.dpr * (0.6 + depth * 1.4));
    o.color = mix(pal(u, 0.6 + uu * 0.3), pal(u, 0.05 + v * 0.7), smoothstep(0.05, 0.6, v)) * (0.5 + v * 1.8 + u.bass * 0.4);
    o.alpha = depth * (0.35 + v * 0.9);
    return o;
}

fragment float4 tideFragment(TideOut in [[stage_in]], float2 pc [[point_coord]]) {
    float m = smoothstep(0.5, 0.15, length(pc - 0.5));
    return float4(in.color * m * in.alpha, m * in.alpha);
}

// Background behind the point cloud.
fragment float4 tideBackground(QuadOut in [[stage_in]],
                               constant Uniforms &u [[buffer(0)]],
                               texture2d<float> specTex [[texture(0)]],
                               texture2d<float> hist [[texture(1)]]) {
    float2 uv = (fragCoord(in.position, u) - 0.5 * u.res) / u.res.y;
    float3 c = mix(u.shadow.rgb * 0.5, u.p2.rgb * 0.18, smoothstep(-0.5, 0.6, uv.y));
    c += u.p1.rgb * 0.18 * exp(-abs(uv.y - 0.28) * 6.0) * (0.5 + u.level);
    return float4(c, 1.0);
}
"""#
}
