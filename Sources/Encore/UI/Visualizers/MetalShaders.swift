// Metal Shading Language source for Encore's GPU visualisers.
//
// The renderer is a small multi-pass pipeline modelled on the techniques that
// make the best visualisers look premium (MilkDrop/Butterchurn feedback, the
// additive particle glow of Magnetosphere, film-style post-processing):
//
//   1. scene      → HDR scene texture (fragment scene, or background + particles)
//   2. feedback   → accum = scene + warp(previous accum) × decay   (light trails)
//   3. bloom      → bright pass + 5-level dual-filter down/up chain
//   4. composite  → accum + bloom, ACES tonemap, vignette, subtle chromatic
//                   aberration on beats, film grain/dither
//
// Compiled at runtime (no .metallib needed); `Scripts/check-shaders.sh`
// compiles it offline in CI so shader mistakes fail the build.

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
    float beat;
    float pad1;
    float4 p0;
    float4 p1;
    float4 p2;
    float4 shadow;
};

struct PassParams {
    float2 srcTexel;
    float2 outSize;
    float decay;
    float zoom;
    float rot;
    float warp;
    float maxMode;
    float threshold;
    float bloomAmt;
    float exposure;
};

constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
constexpr sampler artSampler(coord::normalized, address::mirrored_repeat, filter::linear, mip_filter::linear);

static float hash1(float n) { return fract(sin(n) * 43758.5453123); }
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
    return t.sample(linearSampler, float2(clamp(x, 0.0, 1.0) * 0.92 + 0.02, 0.5), level(0)).r;
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

struct PointOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float3 color;
};

fragment float4 pointFragment(PointOut in [[stage_in]], float2 pc [[point_coord]]) {
    float m = smoothstep(0.5, 0.05, length(pc - 0.5));
    return float4(in.color * m, 1.0);
}

// ================================================================ post-processing

fragment float4 feedbackFragment(QuadOut in [[stage_in]],
                                 constant Uniforms &u [[buffer(0)]],
                                 constant PassParams &pp [[buffer(1)]],
                                 texture2d<float> sceneTex [[texture(0)]],
                                 texture2d<float> prevTex [[texture(1)]]) {
    float2 uv = in.position.xy / pp.outSize;
    // Clamp HDR: dense additive particles can otherwise overflow half floats to
    // infinity, which tonemaps to black.
    float3 sc = clamp(sceneTex.sample(linearSampler, uv).rgb, 0.0, 48.0);
    if (any(isnan(sc))) sc = float3(0.0);
    float3 prev = float3(0.0);
    if (pp.decay > 0.0) {
        float aspect = pp.outSize.x / pp.outSize.y;
        float2 c = uv - 0.5;
        c.x *= aspect;
        c = rot(pp.rot) * c / pp.zoom;
        c += pp.warp * 0.012 * float2(sin(c.y * 6.0 + u.time * 0.6) + sin(c.y * 13.0 - u.time * 0.9) * 0.4,
                                      cos(c.x * 5.0 - u.time * 0.5) + cos(c.x * 11.0 + u.time * 0.8) * 0.4);
        c.x /= aspect;
        prev = prevTex.sample(linearSampler, c + 0.5).rgb;
        prev = max(prev * pp.decay - 0.0015, 0.0);
    }
    return float4(min(mix(sc + prev, max(sc, prev), pp.maxMode), 48.0), 1.0);
}

fragment float4 brightFragment(QuadOut in [[stage_in]],
                               constant PassParams &pp [[buffer(1)]],
                               texture2d<float> src [[texture(0)]]) {
    float2 uv = in.position.xy / pp.outSize;
    float3 c = src.sample(linearSampler, uv).rgb;
    float l = max(c.r, max(c.g, c.b));
    float knee = 0.5;
    float soft = clamp(l - pp.threshold + knee, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee + 1e-4);
    float w = max(soft, l - pp.threshold) / max(l, 1e-4);
    return float4(c * w, 1.0);
}

fragment float4 downFragment(QuadOut in [[stage_in]],
                             constant PassParams &pp [[buffer(1)]],
                             texture2d<float> src [[texture(0)]]) {
    float2 uv = in.position.xy / pp.outSize;
    float2 h = pp.srcTexel;
    float3 s = src.sample(linearSampler, uv).rgb * 4.0;
    s += src.sample(linearSampler, uv - h).rgb + src.sample(linearSampler, uv + h).rgb;
    s += src.sample(linearSampler, uv + float2(h.x, -h.y)).rgb + src.sample(linearSampler, uv - float2(h.x, -h.y)).rgb;
    return float4(s / 8.0, 1.0);
}

fragment float4 upFragment(QuadOut in [[stage_in]],
                           constant PassParams &pp [[buffer(1)]],
                           texture2d<float> src [[texture(0)]],
                           texture2d<float> base [[texture(1)]]) {
    float2 uv = in.position.xy / pp.outSize;
    float2 h = pp.srcTexel;
    float3 s = src.sample(linearSampler, uv + float2(-h.x * 2.0, 0.0)).rgb + src.sample(linearSampler, uv + float2(h.x * 2.0, 0.0)).rgb;
    s += src.sample(linearSampler, uv + float2(0.0, -h.y * 2.0)).rgb + src.sample(linearSampler, uv + float2(0.0, h.y * 2.0)).rgb;
    s += (src.sample(linearSampler, uv + h).rgb + src.sample(linearSampler, uv - h).rgb
          + src.sample(linearSampler, uv + float2(h.x, -h.y)).rgb + src.sample(linearSampler, uv - float2(h.x, -h.y)).rgb) * 2.0;
    return float4(s / 12.0 + base.sample(linearSampler, uv).rgb, 1.0);
}

static float3 aces(float3 x) { return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0); }

fragment float4 compositeFragment(QuadOut in [[stage_in]],
                                  constant Uniforms &u [[buffer(0)]],
                                  constant PassParams &pp [[buffer(1)]],
                                  texture2d<float> src [[texture(0)]],
                                  texture2d<float> bloom [[texture(1)]]) {
    float2 uv = in.position.xy / pp.outSize;
    float2 d = uv - 0.5;
    float ca = 0.0012 + u.beat * 0.0018;
    float3 col = float3(src.sample(linearSampler, uv - d * ca).r, src.sample(linearSampler, uv).g, src.sample(linearSampler, uv + d * ca).b);
    col += bloom.sample(linearSampler, uv).rgb * pp.bloomAmt * 0.2;
    col *= pp.exposure;
    col = aces(col);
    col = pow(col, float3(1.0 / 1.12));
    float vig = smoothstep(1.15, 0.25, length(d * float2(1.0, 0.9)));
    col *= mix(0.55, 1.0, vig);
    col += (hash2(in.position.xy + fract(u.time) * 91.0) - 0.5) * (2.5 / 255.0);
    return float4(col, 1.0);
}

// ================================================================ Swarm
// Magnetosphere-inspired: tens of thousands of particles orbit spinning,
// glowing cores; every particle listens to its own frequency band.

static float3 orbCenter(int k, float t) {
    float fk = float(k);
    return float3(sin(t * 0.13 + fk * 2.1) * 1.3, cos(t * 0.11 + fk * 1.7) * 0.7, sin(t * 0.09 + fk * 4.0) * 0.8);
}
static float3 swarmCamera(float t) { float ca = t * 0.05; return float3(sin(ca) * 4.6, 0.6, cos(ca) * 4.6); }

fragment float4 swarmBackground(QuadOut in [[stage_in]],
                                constant Uniforms &u [[buffer(0)]],
                                texture2d<float> specTex [[texture(0)]]) {
    float2 uv = (fragCoord(in.position, u) - 0.5 * u.res) / u.res.y;
    float3 c = u.shadow.rgb * 0.5;
    float3 ro = swarmCamera(u.time);
    float3 fw = normalize(-ro), rt = normalize(cross(float3(0, 1, 0), fw)), up = cross(fw, rt);
    float3 rd = normalize(fw * 1.6 + rt * uv.x + up * uv.y);
    for (int k = 0; k < 3; k++) {
        float3 oc = orbCenter(k, u.time);
        float s = spec(specTex, float(k) * 0.28 + 0.03);
        float R = 0.035 + 0.02 * s + 0.025 * u.beat;
        float3 L = oc - ro;
        float tca = dot(L, rd);
        float d = sqrt(max(dot(L, L) - tca * tca, 0.0));
        float3 col = pal(u, float(k) * 0.33 + 0.05);
        c += col * exp(-d / (R * 2.5)) * (0.25 + 0.7 * s) + mix(col, float3(1.0), 0.6) * smoothstep(R, R * 0.5, d) * 1.2;
    }
    return float4(c, 1.0);
}

static float3x3 axisRot(float3 a, float ang) {
    a = normalize(a);
    float s = sin(ang), c = cos(ang), oc = 1.0 - c;
    return float3x3(float3(oc * a.x * a.x + c, oc * a.x * a.y + a.z * s, oc * a.z * a.x - a.y * s),
                    float3(oc * a.x * a.y - a.z * s, oc * a.y * a.y + c, oc * a.y * a.z + a.x * s),
                    float3(oc * a.z * a.x + a.y * s, oc * a.y * a.z - a.x * s, oc * a.z * a.z + c));
}

vertex PointOut swarmVertex(uint vid [[vertex_id]],
                            constant Uniforms &u [[buffer(0)]],
                            texture2d<float> specTex [[texture(0)]]) {
    float id = float(vid);
    int k = int(vid % 3);
    float h1 = hash1(id * 1.13), h2 = hash1(id * 7.31 + 1.0), h3 = hash1(id * 3.77 + 2.0), h4 = hash1(id * 0.61 + 5.0);
    float e = spec(specTex, h4);
    float r0 = 0.18 + pow(h1, 1.6) * 1.15;
    float r = r0 * (1.0 + 0.55 * e * e) + u.beat * 0.08 * (1.0 - h1);
    float w = 0.55 / pow(r0 + 0.15, 1.5);
    float ang = h2 * 6.2831 + u.time * w * (0.6 + 0.6 * u.level);
    float tilt = (h3 - 0.5) * 0.9 * (0.3 + r0);
    float3 p = float3(cos(ang) * r, sin(ang * 2.0 + h3 * 6.0) * 0.06 + tilt * 0.25, sin(ang) * r);
    float3 axis = float3(sin(float(k) * 2.0 + 0.4), 1.0, cos(float(k) * 1.3));
    p = axisRot(axis, 0.6 + float(k) * 0.8) * p;
    p += orbCenter(k, u.time);
    float3 ro = swarmCamera(u.time);
    float3 fw = normalize(-ro), rt = normalize(cross(float3(0, 1, 0), fw)), up = cross(fw, rt);
    float3 q = p - ro;
    float3 v = float3(dot(q, rt), dot(q, up), dot(q, fw));
    PointOut o;
    o.position = float4(v.x * 1.6 / (u.res.x / u.res.y), v.y * 1.6, v.z * 0.05, v.z);
    o.pointSize = clamp(7.0 / max(v.z, 0.1), 1.5, 12.0) * u.dpr;
    float3 col = mix(pal(u, float(k) * 0.33 + 0.05), pal(u, float(k) * 0.33 + 0.35), h1);
    col = mix(col, float3(1.0), e * e * 0.35);
    o.color = min(col * (0.12 + 1.1 * e * e + 0.3 * u.beat) * (2.4 / (max(v.z, 0.5) * 0.5 + 0.3)) / (u.dpr * u.dpr), 2.0);
    return o;
}

// ================================================================ Flow
// MilkDrop-style: a glowing spectrum ring is drawn each frame; the feedback
// pass zooms, swirls and fades it into rivers of light.

fragment float4 flowFragment(QuadOut in [[stage_in]],
                             constant Uniforms &u [[buffer(0)]],
                             texture2d<float> specTex [[texture(0)]]) {
    float2 uv = (fragCoord(in.position, u) - 0.5 * u.res) / u.res.y;
    float r = length(uv), a = atan2(uv.y, uv.x);
    float seg = abs(fract(a / (2.0 * M_PI_F) + 0.25) * 2.0 - 1.0);
    float s = spec(specTex, seg * 0.85);
    float ringR = 0.16 + 0.10 * s + 0.03 * u.beat;
    float d = abs(r - ringR);
    float line = exp(-d * d / 0.00002) * (0.6 + 1.6 * s);
    float3 col = pal(u, seg * 0.6 + u.phase * 0.05) * line * 1.3;
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float2 sp = 0.12 * float2(cos(u.time * (0.7 + fi * 0.13) + fi * 2.0), sin(u.time * (0.9 + fi * 0.11) + fi));
        col += pal(u, fi / 6.0) * exp(-dot(uv - sp, uv - sp) / 0.00006) * (0.4 + u.treble);
    }
    return float4(col, 1.0);
}

// ================================================================ Ambient
// Apple-Music-style: the artwork itself, slowly swirled and blurred into a
// living painting whose light breathes with the music.

fragment float4 ambientFragment(QuadOut in [[stage_in]],
                                constant Uniforms &u [[buffer(0)]],
                                texture2d<float> specTex [[texture(0)]],
                                texture2d<float> artTex [[texture(2)]]) {
    float2 uv = fragCoord(in.position, u) / u.res;
    float aspect = u.res.x / u.res.y;
    float2 p = (uv - 0.5) * float2(aspect, 1.0);
    float t = u.time * 0.04 + u.phase * 0.02;
    float2 w1 = float2(fbm3(p * 0.9 + float2(t, 0.0)), fbm3(p * 0.9 + float2(4.0, 1.0) - t)) - 0.5;
    float2 w2 = float2(fbm3(p * 1.6 + w1 * 2.0 - t * 0.7), fbm3(p * 1.6 + w1 * 2.0 + float2(2.0, 7.0) + t * 0.5)) - 0.5;
    float lodBase = log2(max(float(artTex.get_width()), 1.0)) - 5.0;   // ~32 px detail regardless of artwork size
    float3 col = float3(0.0);
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float2 q = rot(t * (0.6 + fi * 0.35) + fi * 2.1) * (p * (0.45 + fi * 0.14) + w2 * (0.45 + fi * 0.15));
        col += artTex.sample(artSampler, q + 0.5, level(max(lodBase + 0.4 + fi * 0.5, 0.0))).rgb;
    }
    col /= 3.0;
    float l = dot(col, float3(0.299, 0.587, 0.114));
    col = mix(float3(l), col, 1.7);
    col = pow(max(col, 0.0), float3(2.2)) * 1.25;
    float shade = fbm3(p * 1.3 + w2 * 3.0 + t * 0.5);
    col *= 0.45 + 0.9 * shade;
    col *= 0.8 + 0.35 * u.level + 0.25 * u.beat;
    return float4(col, 1.0);
}

// ================================================================ Aurora
// Tall curtains of light over a night sky; they rise and glow with the music.

fragment float4 auroraFragment(QuadOut in [[stage_in]],
                               constant Uniforms &u [[buffer(0)]],
                               texture2d<float> specTex [[texture(0)]]) {
    float2 fc = fragCoord(in.position, u);
    float2 uv = fc / u.res;
    float aspect = u.res.x / u.res.y;
    float x0 = (uv.x - 0.5) * aspect;
    float t = u.time * 0.5 + u.phase * 0.25;
    float3 sky = mix(u.shadow.rgb * 1.2 + pal(u, 0.66) * 0.05, float3(0.003, 0.005, 0.014), smoothstep(0.05, 1.0, uv.y));
    float2 sc = floor(fc / (2.2 * u.dpr));
    float star = step(0.9965, hash2(sc)) * (0.55 + 0.45 * sin(u.time * (0.8 + hash2(sc + 3.1) * 2.0) + hash2(sc) * 40.0));
    sky += float3(0.9, 0.95, 1.0) * star * smoothstep(0.3, 0.8, uv.y) * 1.2;
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
        col += pal(u, 0.08 + fi * 0.2) * exp(-abs(y) * 70.0) * smoothstep(-0.015, 0.0, y) * 0.5 * (0.5 + s);
    }
    float hill = 0.16 + 0.045 * gnoise(float2(x0 * 1.6, 1.0)) + 0.015 * gnoise(float2(x0 * 8.0, 4.0));
    col *= 2.0 * (0.85 + 0.3 * u.beat);
    float3 c = sky + col;
    float land = smoothstep(hill + 0.002, hill - 0.002, uv.y);
    c = mix(c, u.shadow.rgb * 0.3 + col * 0.05, land);
    return float4(c, 1.0);
}

// ================================================================ Halo
// The artwork in a disc, ringed by a radial spectrum of light with soft trails.

fragment float4 haloFragment(QuadOut in [[stage_in]],
                             constant Uniforms &u [[buffer(0)]],
                             texture2d<float> specTex [[texture(0)]],
                             texture2d<float> artTex [[texture(2)]]) {
    float2 uv = (fragCoord(in.position, u) - 0.5 * u.res) / u.res.y - float2(0.0, 0.06);
    float r = length(uv), a = atan2(uv.y, uv.x);
    float R = 0.2 * (1.0 + 0.04 * u.beat);
    float3 col = float3(0.0);
    float n = 96.0;
    float fa = fract(a / (2.0 * M_PI_F) + 0.25);
    float cell = floor(fa * n);
    float centerA = (cell + 0.5) / n;
    float seg = abs(centerA * 2.0 - 1.0);
    float s = spec(specTex, seg * 0.85);
    float len = 0.015 + s * 0.20;
    float aDist = abs(fa - centerA) * 2.0 * M_PI_F * r;
    float px = 1.0 / u.res.y;
    float inBar = smoothstep(0.004 + px, 0.0015, aDist) * smoothstep(R + 0.012, R + 0.02, r) * smoothstep(R + 0.024 + len, R + 0.02 + len, r);
    col += pal(u, seg * 0.6 + u.phase * 0.03) * inBar * (0.8 + 2.0 * s);
    col += pal(u, 0.1) * exp(-abs(r - R - 0.008) * 160.0) * (0.6 + 1.2 * u.level);
    if (r < R) {
        float2 auv = float2(uv.x, -uv.y) / (2.0 * R) + 0.5;
        float3 art = artTex.sample(artSampler, auv, level(0)).rgb;
        float edge = smoothstep(R, R - 0.004, r);
        col = mix(col, art * (0.9 + 0.2 * u.beat), edge);
    }
    return float4(col, 1.0);
}

// ================================================================ Orb
// A glass sphere rippling with the spectrum; bloom makes the rim sing.

static float mapOrb(float3 p, constant Uniforms &u, texture2d<float> specTex, float R) {
    p.xz = rot(u.time * 0.1) * p.xz;
    p.yz = rot(0.3) * p.yz;
    float ang = atan2(p.z, p.x) / (2.0 * M_PI_F) + 0.5;
    float s = spec(specTex, abs(ang * 2.0 - 1.0) * 0.8);
    float d = length(p) - R;
    float w = sin(p.x * 3.1 + u.time * 0.5) * sin(p.y * 2.7 - u.time * 0.4) * sin(p.z * 3.3 + u.time * 0.45);
    d -= w * (0.018 + 0.03 * u.level) + s * 0.05 * (0.5 + 0.5 * sin(p.y * 7.0 + u.time * 0.7));
    return d * 0.9;
}

fragment float4 orbFragment(QuadOut in [[stage_in]],
                            constant Uniforms &u [[buffer(0)]],
                            texture2d<float> specTex [[texture(0)]]) {
    float2 uv = (fragCoord(in.position, u) - 0.5 * u.res) / u.res.y - float2(0.0, 0.08);
    float R = 0.5 + u.bass * 0.04 + u.beat * 0.03;
    float3 ro = float3(0.0, 0.0, 3.0), rd = normalize(float3(uv, -1.7));
    float3 bg = u.shadow.rgb * 0.6;
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float2 g = (uv + float2(u.time * 0.008 * (fi + 1.0), u.time * 0.005)) * (12.0 + fi * 8.0);
        float2 id = floor(g); float2 f = fract(g) - 0.5;
        float h = hash2(id + fi * 7.0);
        float2 o = float2(hash2(id + 1.3), hash2(id + 2.7)) - 0.5;
        bg += pal(u, h) * smoothstep(0.05, 0.0, length(f - o * 0.7)) * step(0.86, h) * (0.4 + 0.6 * u.treble);
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
    float3 col = bg + pal(u, 0.1 + u.phase * 0.02) * exp(-max(minD, 0.0) * 8.0) * (0.35 + 0.8 * u.level);
    if (hit) {
        float3 p = ro + rd * t;
        float2 e = float2(0.002, 0.0);
        float3 n = normalize(float3(mapOrb(p + e.xyy, u, specTex, R) - mapOrb(p - e.xyy, u, specTex, R),
                                    mapOrb(p + e.yxy, u, specTex, R) - mapOrb(p - e.yxy, u, specTex, R),
                                    mapOrb(p + e.yyx, u, specTex, R) - mapOrb(p - e.yyx, u, specTex, R)));
        float facing = max(dot(n, -rd), 0.0), fres = pow(1.0 - facing, 3.0);
        float3 L = normalize(float3(-0.5, 0.65, 0.6));
        float3 rr = refract(rd, n, 0.78);
        float sw = gnoise(rr.xy * 2.4 + float2(u.time * 0.05, -u.time * 0.03));
        col = bg * 0.5 + pal(u, 0.55 + sw * 0.4) * 0.22 * (0.6 + u.level) + pal(u, 0.12) * pow(facing, 7.0) * (0.3 + 0.6 * u.level);
        col += fres * pal(u, 0.25 + n.y * 0.15) * 2.4;
        col += pal(u, fres * 0.7 + n.x * 0.2) * fres * 0.8;
        col += pow(max(dot(reflect(rd, n), L), 0.0), 60.0) * 2.0;
    }
    return float4(col, 1.0);
}

// ================================================================ Tide
// A sea of light points; the newest sound arrives in the foreground.

fragment float4 tideBackground(QuadOut in [[stage_in]],
                               constant Uniforms &u [[buffer(0)]],
                               texture2d<float> specTex [[texture(0)]]) {
    float2 uv = (fragCoord(in.position, u) - 0.5 * u.res) / u.res.y;
    float3 c = mix(u.shadow.rgb * 0.5, u.shadow.rgb * 0.9 + u.p2.rgb * 0.08, smoothstep(-0.5, 0.45, uv.y));
    c += u.p1.rgb * 0.18 * exp(-abs(uv.y - 0.2) * 7.0) * (0.5 + u.level);
    return float4(c, 1.0);
}

vertex PointOut tideVertex(uint vid [[vertex_id]],
                           constant Uniforms &u [[buffer(0)]],
                           texture2d<float> specTex [[texture(0)]],
                           texture2d<float> hist [[texture(1)]]) {
    float i = float(vid);
    float cx = i - 220.0 * floor(i / 220.0), cz = floor(i / 220.0);
    float uu = cx / 219.0, w = (cz + u.scroll) / 110.0;
    float fx = abs(uu * 2.0 - 1.0);
    float v = hist.sample(linearSampler, float2(fx * 0.8 + 0.03, clamp(w, 0.0, 1.0)), level(0)).r;
    float x = (uu - 0.5) * 40.0, z = w * 70.0 + 2.0;
    float y = sin(x * 0.22 + u.time * 0.5 + z * 0.09) * 0.55 + sin(z * 0.18 - u.time * 0.35 + x * 0.05) * 0.6;
    y += pow(v, 1.4) * 6.5 * (1.0 - fx * 0.55);
    float3 pw = float3(x, y, z) - float3(0.0, 7.0, -3.0);
    float pitch = 0.36, cp = cos(pitch), sp = sin(pitch);
    float3 pc = float3(pw.x, pw.y * cp + pw.z * sp, -pw.y * sp + pw.z * cp);
    PointOut o;
    o.position = float4(pc.x * 1.35 / (u.res.x / u.res.y), pc.y * 1.35, pc.z * 0.01, pc.z);
    float depth = clamp(1.0 - w, 0.0, 1.0);
    o.pointSize = max(1.0, (1.2 + v * 2.2) * (0.55 + depth * 1.25)) * u.dpr;
    float3 col = mix(pal(u, 0.6 + uu * 0.25), pal(u, 0.05 + v * 0.6), smoothstep(0.1, 0.7, v));
    o.color = col * (0.25 + v * v * 3.0 + u.beat * 0.3) * depth * depth;
    return o;
}
"""#
}
