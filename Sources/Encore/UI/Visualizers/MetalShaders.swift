// Metal Shading Language source for Encore's GPU visualiser scenes.
//
// Compiled at runtime with `MTLDevice.makeLibrary(source:options:)`, so the
// app needs no precompiled .metallib and builds with plain `swift build`.
// `Scripts/check-shaders.sh` compiles it offline in CI so mistakes fail early.
//
// Every scene reads the same uniforms: smoothed loudness values, a 64-bin
// spectrum texture and a 64×64 spectrum-history texture (newest row first).
// The look is deliberately calm: slow motion, soft light, colours taken from
// the current video's artwork, a gentle tonemap and dithering (no banding).

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

static float hash2(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
static float2 grad2(float2 i) { float a = hash2(i) * 6.2831853; return float2(cos(a), sin(a)); }
static float gnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float a = dot(grad2(i), f), b = dot(grad2(i + float2(1, 0)), f - float2(1, 0));
    float c = dot(grad2(i + float2(0, 1)), f - float2(0, 1)), d = dot(grad2(i + float2(1, 1)), f - float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y) * 0.7 + 0.5;
}
static float fbm3(float2 p) {
    float v = 0.0, a = 0.5;
    float2x2 m = float2x2(float2(1.6, 1.2), float2(-1.2, 1.6));
    for (int i = 0; i < 3; i++) { v += a * gnoise(p); p = m * p; a *= 0.5; }
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
static float3 finish(float3 c, float2 fc, constant Uniforms &u) {
    c = max(c, 0.0);
    c = c / (1.0 + c * 0.45);
    c = pow(c, float3(0.95));
    c += (hash2(fc + fract(u.time) * 91.0) - 0.5) / 255.0 * 2.0;
    return c;
}
static float2 fragCoord(float4 pos, constant Uniforms &u) { return float2(pos.x, u.res.y - pos.y); }
static float2x2 rot(float a) { float c = cos(a), s = sin(a); return float2x2(float2(c, -s), float2(s, c)); }

struct QuadOut { float4 position [[position]]; };

vertex QuadOut quadVertex(uint vid [[vertex_id]]) {
    const float2 P[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    QuadOut o;
    o.position = float4(P[vid], 0, 1);
    return o;
}

// ---------------------------------------------------------------- Silk
// Large, slow-moving fields of colour with satin folds.

fragment float4 silkFragment(QuadOut in [[stage_in]],
                             constant Uniforms &u [[buffer(0)]],
                             texture2d<float> specTex [[texture(0)]],
                             texture2d<float> hist [[texture(1)]]) {
    float2 fc = fragCoord(in.position, u);
    float2 uv = (fc - 0.5 * u.res) / u.res.y;
    float t = u.time * 0.045 + u.phase * 0.03;
    float2 w = float2(fbm3(uv * 0.8 + float2(t, 0.0)), fbm3(uv * 0.8 + float2(3.1, 1.7) - t)) - 0.5;
    float2 p = uv + w * 0.7;
    float3 col = u.shadow.rgb * 0.9;
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        float2 c = float2(0.62 * sin(t * (0.9 + fi * 0.27) + fi * 2.1), 0.36 * cos(t * (0.7 + fi * 0.19) + fi * 1.3));
        float r = 0.42 + 0.16 * spec(specTex, fi / 4.0 + 0.05) + 0.08 * u.bass;
        float wgt = exp(-dot(p - c, p - c) / (r * r));
        col += pal(u, fi * 0.27 + t * 0.03) * wgt * 0.7;
    }
    col = mix(u.shadow.rgb * 0.8, col, smoothstep(0.0, 0.55, length(col)));
    float folds = sin((p.x * 0.8 + p.y) * 5.5 + w.x * 9.0 + t * 1.5);
    float folds2 = sin((p.x - p.y * 0.7) * 3.2 - w.y * 7.0 - t * 1.1);
    float sheen = pow(folds * 0.5 + 0.5, 18.0) + 0.6 * pow(folds2 * 0.5 + 0.5, 24.0);
    col += mix(float3(1.0), pal(u, 0.2), 0.4) * sheen * (0.08 + 0.18 * u.level);
    col *= 0.85 + 0.25 * u.level + 0.15 * u.bass;
    col *= 1.0 - 0.32 * dot(uv, uv);
    return float4(finish(col, fc, u), 1.0);
}

// ---------------------------------------------------------------- Aurora
// Tall curtains of light over a night sky; they rise and glow with the music.

fragment float4 auroraFragment(QuadOut in [[stage_in]],
                               constant Uniforms &u [[buffer(0)]],
                               texture2d<float> specTex [[texture(0)]],
                               texture2d<float> hist [[texture(1)]]) {
    float2 fc = fragCoord(in.position, u);
    float2 uv = fc / u.res;
    float aspect = u.res.x / u.res.y;
    float x0 = (uv.x - 0.5) * aspect;
    float t = u.time * 0.5 + u.phase * 0.25;
    float3 sky = mix(u.shadow.rgb * 1.2 + pal(u, 0.66) * 0.05, float3(0.003, 0.005, 0.014), smoothstep(0.05, 1.0, uv.y));
    float2 sc = floor(fc / (2.2 * u.dpr));
    float star = step(0.9965, hash2(sc)) * (0.55 + 0.45 * sin(u.time * (0.8 + hash2(sc + 3.1) * 2.0) + hash2(sc) * 40.0));
    sky += float3(0.9, 0.95, 1.0) * star * smoothstep(0.3, 0.8, uv.y) * 0.7;
    float3 col = float3(0.0);
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float xr = x0 * 0.75 + fi * 0.53;
        float base = 0.26 + fi * 0.06 + 0.12 * sin(xr * 1.05 + t * 0.09 + fi * 2.0) + 0.07 * (gnoise(float2(xr * 1.3 + t * 0.04, fi * 3.0)) - 0.5);
        float y = uv.y - base;
        float x = xr + 0.035 * sin(y * 9.0 + t * 0.3 + fi);
        float s = spec(specTex, abs(uv.x * 2.0 - 1.0) * 0.8 + fi * 0.04);
        float h = 0.26 + 0.36 * s + 0.10 * u.level;
        float shape = smoothstep(-0.012, 0.01, y) * exp(-max(y, 0.0) / h * 1.7);
        float r = gnoise(float2(x * 30.0 + y * 1.5, t * 0.12 + fi * 5.0));
        float rays = pow(clamp(r, 0.0, 1.0), 1.6) * 1.7;
        rays *= 0.7 + 0.3 * gnoise(float2(x * 5.0 - t * 0.08, fi * 2.0));
        rays *= 0.25 + 0.75 * smoothstep(0.3, 0.72, gnoise(float2(x * 1.9 + t * 0.05, fi * 7.0)));
        float3 c = mix(pal(u, 0.08 + fi * 0.2), pal(u, 0.55 + fi * 0.1), smoothstep(0.0, h * 1.1, y));
        col += c * shape * rays * (0.5 + 1.0 * s) * (0.62 - fi * 0.12);
        col += pal(u, 0.08 + fi * 0.2) * exp(-abs(y) * 70.0) * smoothstep(-0.015, 0.0, y) * 0.35 * (0.5 + s);
    }
    float hill = 0.16 + 0.045 * gnoise(float2(x0 * 1.6, 1.0)) + 0.015 * gnoise(float2(x0 * 8.0, 4.0));
    col *= 1.7;
    float3 c = sky + col;
    c += col * col * 0.35;
    float land = smoothstep(hill + 0.002, hill - 0.002, uv.y);
    c = mix(c, u.shadow.rgb * 0.3 + col * 0.05, land);
    return float4(finish(c, fc, u), 1.0);
}

// ---------------------------------------------------------------- Orb
// A luminous glass sphere; its skin ripples gently with the spectrum.

static float mapOrb(float3 p, constant Uniforms &u, texture2d<float> specTex, float R) {
    p.xz = rot(u.time * 0.1) * p.xz;
    p.yz = rot(0.3) * p.yz;
    float ang = atan2(p.z, p.x) / (2.0 * M_PI_F) + 0.5;
    float s = spec(specTex, abs(ang * 2.0 - 1.0) * 0.8);
    float d = length(p) - R;
    float w = sin(p.x * 3.1 + u.time * 0.5) * sin(p.y * 2.7 - u.time * 0.4) * sin(p.z * 3.3 + u.time * 0.45);
    d -= w * (0.018 + 0.03 * u.level) + s * 0.045 * (0.5 + 0.5 * sin(p.y * 7.0 + u.time * 0.7));
    return d * 0.9;
}

fragment float4 orbFragment(QuadOut in [[stage_in]],
                            constant Uniforms &u [[buffer(0)]],
                            texture2d<float> specTex [[texture(0)]],
                            texture2d<float> hist [[texture(1)]]) {
    float2 fc = fragCoord(in.position, u);
    float2 uv = (fc - 0.5 * u.res) / u.res.y;
    float R = 0.62 + u.bass * 0.05;
    float3 ro = float3(0.0, 0.0, 3.0), rd = normalize(float3(uv, -1.7));
    float3 bg = u.shadow.rgb * 1.0 + pal(u, 0.66) * 0.07 * exp(-length(uv) * 1.4) * (0.7 + u.level);
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float2 g = (uv + float2(u.time * 0.008 * (fi + 1.0), u.time * 0.005)) * (12.0 + fi * 8.0);
        float2 id = floor(g); float2 f = fract(g) - 0.5;
        float h = hash2(id + fi * 7.0);
        float2 o = float2(hash2(id + 1.3), hash2(id + 2.7)) - 0.5;
        bg += pal(u, h) * smoothstep(0.05, 0.0, length(f - o * 0.7)) * step(0.85, h) * (0.18 + 0.3 * u.treble);
    }
    float t = 0.0, minD = 10.0;
    bool hit = false;
    for (int i = 0; i < 64; i++) {
        float d = mapOrb(ro + rd * t, u, specTex, R);
        minD = min(minD, d);
        if (d < 0.001) { hit = true; break; }
        t += d;
        if (t > 6.0) break;
    }
    float3 col = bg + pal(u, 0.1 + u.phase * 0.02) * exp(-max(minD, 0.0) * 9.0) * (0.25 + 0.55 * u.level);
    if (hit) {
        float3 p = ro + rd * t;
        float2 e = float2(0.002, 0.0);
        float3 n = normalize(float3(mapOrb(p + e.xyy, u, specTex, R) - mapOrb(p - e.xyy, u, specTex, R),
                                    mapOrb(p + e.yxy, u, specTex, R) - mapOrb(p - e.yxy, u, specTex, R),
                                    mapOrb(p + e.yyx, u, specTex, R) - mapOrb(p - e.yyx, u, specTex, R)));
        float facing = max(dot(n, -rd), 0.0);
        float fres = pow(1.0 - facing, 3.0);
        float3 L = normalize(float3(-0.5, 0.65, 0.6));
        float3 rr = refract(rd, n, 0.78);
        float sw = gnoise(rr.xy * 2.4 + float2(u.time * 0.05, -u.time * 0.03));
        float3 body = bg * 0.55 + pal(u, 0.55 + sw * 0.4) * 0.16 * (0.6 + u.level) + pal(u, 0.12) * pow(facing, 7.0) * (0.18 + 0.35 * u.level);
        col = body;
        col += fres * pal(u, 0.25 + n.y * 0.15) * 1.7;
        col += pal(u, fres * 0.7 + n.x * 0.2) * fres * 0.5;
        col += pow(max(dot(reflect(rd, n), L), 0.0), 60.0) * 0.85;
        col += pow(max(dot(reflect(rd, n), normalize(float3(0.7, -0.3, 0.6))), 0.0), 20.0) * pal(u, 0.5) * 0.25;
    }
    col *= 1.0 - 0.28 * dot(uv, uv);
    return float4(finish(col, fc, u), 1.0);
}

// ---------------------------------------------------------------- Tide
// A soft holographic sea of points: rows carry the recent past, columns the frequencies.

constant float TIDE_COLS = 220.0;
constant float TIDE_ROWS = 110.0;

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
    float x = (uu - 0.5) * 40.0;
    float z = w * 70.0 + 2.0;
    float y = sin(x * 0.22 + u.time * 0.5 + z * 0.09) * 0.55 + sin(z * 0.18 - u.time * 0.35 + x * 0.05) * 0.6;
    y += pow(v, 1.4) * 6.0 * (1.0 - fx * 0.55);
    float3 pw = float3(x, y, z) - float3(0.0, 7.0, -3.0);
    float pitch = 0.36, cp = cos(pitch), sp = sin(pitch);
    float3 pc = float3(pw.x, pw.y * cp + pw.z * sp, -pw.y * sp + pw.z * cp);
    TideOut o;
    o.position = float4(pc.x * 1.35 / (u.res.x / u.res.y), pc.y * 1.35, pc.z * 0.01, pc.z);
    float depth = clamp(1.0 - w, 0.0, 1.0);
    o.pointSize = max(1.0, (1.0 + v * 2.0) * u.dpr * (0.55 + depth * 1.25));
    o.color = mix(pal(u, 0.6 + uu * 0.25), pal(u, 0.05 + v * 0.6), smoothstep(0.1, 0.7, v)) * (0.6 + v * 1.5 + u.bass * 0.3);
    o.alpha = depth * depth * (0.28 + v * 0.75);
    return o;
}

fragment float4 tideFragment(TideOut in [[stage_in]], float2 pc [[point_coord]]) {
    float m = smoothstep(0.5, 0.1, length(pc - 0.5));
    return float4(in.color * m * in.alpha, m * in.alpha);
}

fragment float4 tideBackground(QuadOut in [[stage_in]],
                               constant Uniforms &u [[buffer(0)]],
                               texture2d<float> specTex [[texture(0)]],
                               texture2d<float> hist [[texture(1)]]) {
    float2 fc = fragCoord(in.position, u);
    float2 uv = (fc - 0.5 * u.res) / u.res.y;
    float3 c = mix(u.shadow.rgb * 0.7, u.shadow.rgb * 1.1 + u.p2.rgb * 0.10, smoothstep(-0.5, 0.45, uv.y));
    c += u.p1.rgb * 0.16 * exp(-abs(uv.y - 0.2) * 7.0) * (0.5 + u.level);
    c *= 1.0 - 0.3 * dot(uv, uv);
    return float4(finish(c, fc, u), 1.0);
}
"""#
}
