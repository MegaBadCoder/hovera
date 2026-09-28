extension Renderer {
    static let skyShaderSource = """

    struct SkyUniforms { float4x4 inverseViewProjection; float4 params; };
    struct SkyOut { float4 position [[position]]; float2 ndc; };

    vertex SkyOut skyVertex(uint vid [[vertex_id]]) {
        const float2 corners[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        SkyOut out;
        out.position = float4(corners[vid], 0, 1);
        out.ndc = corners[vid];
        return out;
    }

    static float hash31(float3 p) {
        p = fract(p * 0.1031);
        p += dot(p, p.zyx + 31.32);
        return fract((p.x + p.y) * p.z);
    }

    static float3 hash33(float3 p) {
        p = fract(p * float3(0.1031, 0.1030, 0.0973));
        p += dot(p, p.yxz + 33.33);
        return fract((p.xxy + p.yxx) * p.zyx);
    }

    static float valueNoise(float3 p) {
        float3 i = floor(p);
        float3 f = fract(p);
        float3 u = f * f * f * (f * (f * 6 - 15) + 10);
        float n000 = hash31(i);
        float n100 = hash31(i + float3(1, 0, 0));
        float n010 = hash31(i + float3(0, 1, 0));
        float n110 = hash31(i + float3(1, 1, 0));
        float n001 = hash31(i + float3(0, 0, 1));
        float n101 = hash31(i + float3(1, 0, 1));
        float n011 = hash31(i + float3(0, 1, 1));
        float n111 = hash31(i + float3(1, 1, 1));
        return mix(mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y),
                   mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y), u.z);
    }

    constant float3x3 octaveTurn = float3x3(float3(0.00, 0.80, 0.60), float3(-0.80, 0.36, -0.48), float3(-0.60, -0.48, 0.64));

    static float fbm(float3 p, int octaves) {
        float sum = 0;
        float amplitude = 0.5;
        for (int i = 0; i < octaves; i++) {
            sum += amplitude * valueNoise(p);
            p = octaveTurn * p * 2.03;
            amplitude *= 0.5;
        }
        return sum;
    }

    constant float3 sunDirection = float3(0.62, 0.22, -0.75);
    constant float3 nebulaHeart = float3(-0.45, 0.30, -0.84);

    static float angleBetween(float3 a, float3 b) {
        return acos(clamp(dot(a, b), -1.0, 1.0));
    }

    static float4 nebula(float3 dir) {
        float3 heart = normalize(nebulaHeart);
        float3 sun = normalize(sunDirection);
        float3 bandAxis = normalize(float3(0.25, 0.9, 0.35));
        float nearHeart = exp(-pow(angleBetween(dir, heart) / 0.75, 2.0));
        float band = exp(-pow(dot(dir, bandAxis) / 0.22, 2.0));
        float nearSecondHeart = exp(-pow(angleBetween(dir, normalize(float3(0.55, -0.15, 0.82))) / 0.65, 2.0));
        float mask = max(max(nearHeart, nearSecondHeart * 0.85), band * 0.4);
        float glowFromSun = 0.25 + 1.4 * exp(-angleBetween(dir, sun) / 0.30);

        float3 color = float3(0);
        float transmittance = 1;
        const int steps = 40;
        const float stepLength = 0.06;
        for (int i = 0; i < steps; i++) {
            float t = 1.0 + float(i) * stepLength;
            float3 p = dir * t * 1.3;
            float3 warp = float3(fbm(p + float3(1.7, 9.2, 3.3), 4), fbm(p + float3(8.3, 2.8, 5.1), 4), fbm(p + float3(4.4, 6.6, 0.9), 4));
            float gas = fbm(p * 1.5 + warp * 2.2, 5);
            float density = pow(saturate((gas - 0.47) * 3.5), 1.6) * mask;
            float dust = saturate((fbm(p * 2.8 + warp + 13.0, 5) - 0.48) * 4.0) * mask;
            float hue = fbm(p * 0.6 + warp * 0.8 + 20.0, 3);
            float3 warm = mix(float3(0.95, 0.12, 0.38), float3(1.00, 0.52, 0.12), smoothstep(0.35, 0.62, hue));
            float3 cool = mix(float3(0.12, 0.28, 0.95), float3(0.08, 0.78, 0.82), smoothstep(0.30, 0.60, hue));
            float3 emission = mix(cool, warm, smoothstep(0.2, 0.8, nearHeart + 0.3 * (hue - 0.5)));
            color += transmittance * emission * emission * density * glowFromSun * stepLength * 1.1;
            transmittance *= exp(-(density * 0.9 + dust * 3.0) * stepLength * 1.4);
        }
        color += float3(0.004, 0.005, 0.012) * (0.3 + band);
        return float4(color, transmittance);
    }

    static float3 starLayer(float3 dir, float scale, float density, float size, float time, float power) {
        float3 cell = floor(dir * scale);
        float3 h = hash33(cell);
        if (h.x > density) { return float3(0); }
        float3 star = normalize(cell + 0.3 + 0.4 * hash33(cell + 17.0));
        float distance = length(dir - star);
        float twinkle = 0.8 + 0.2 * sin(time * (0.6 + 2.0 * h.z) + h.y * 40.0);
        float brightness = pow(h.y, power) * twinkle;
        float temperature = h.z;
        float3 tint = temperature < 0.3 ? float3(0.65, 0.78, 1.0) : (temperature < 0.8 ? float3(1.0, 0.97, 0.92) : float3(1.0, 0.72, 0.45));
        float insideCell = smoothstep(0.28 / scale, 0.12 / scale, distance);
        float core = exp(-pow(distance / size, 2.0));
        float halo = exp(-distance / (size * 3.0)) * 0.06 * brightness;
        return tint * (brightness * core + halo) * insideCell;
    }

    static float3 stars(float3 dir, float time) {
        float3 color = starLayer(dir, 140.0, 0.30, 0.0007, time, 3.0) * 1.2;
        color += starLayer(dir, 60.0, 0.10, 0.0011, time, 2.0) * 2.0;
        color += starLayer(dir, 22.0, 0.05, 0.0017, time, 1.5) * 5.0;
        return color;
    }

    static float3 sunGlow(float3 dir) {
        float3 sun = normalize(sunDirection);
        float angle = angleBetween(dir, sun);
        float3 east = normalize(cross(sun, float3(0, 1, 0)));
        float3 north = cross(east, sun);
        float2 local = float2(dot(dir, east), dot(dir, north));
        float spikes = exp(-abs(local.x) / 0.0008) * exp(-abs(local.y) / 0.05) + exp(-abs(local.y) / 0.0008) * exp(-abs(local.x) / 0.05);
        float core = smoothstep(0.012, 0.008, angle) * 30.0;
        float glow = exp(-angle / 0.02) * 2.5 + exp(-angle / 0.09) * 0.35 + exp(-angle / 0.35) * 0.05;
        return float3(1.0, 0.93, 0.82) * (core + glow + spikes * 1.2 * step(0.0, dot(dir, sun)));
    }

    static float4 planetColor(float3 dir, float time) {
        float3 center = normalize(float3(-0.30, -0.50, -0.81));
        float radius = 0.30;
        float3 sun = normalize(sunDirection);
        float angle = angleBetween(dir, center);
        float3 east = normalize(cross(center, float3(0, 1, 0)));
        float3 north = cross(east, center);
        float3 color = float3(0);
        float coverage = 0;
        if (angle < radius) {
            float2 local = float2(dot(dir, east), dot(dir, north)) / sin(radius);
            float lz = sqrt(max(0.0, 1.0 - dot(local, local)));
            float3 normal = normalize(east * local.x + north * local.y - center * lz);
            float spin = time * 0.004;
            float3 surfacePoint = float3(normal.x * cos(spin) - normal.z * sin(spin), normal.y, normal.x * sin(spin) + normal.z * cos(spin));
            float land = smoothstep(0.50, 0.53, fbm(surfacePoint * 3.2 + 5.0, 7));
            float3 ground = mix(float3(0.015, 0.05, 0.14), mix(float3(0.16, 0.13, 0.08), float3(0.07, 0.12, 0.05), fbm(surfacePoint * 6.0, 4)), land);
            float clouds = smoothstep(0.50, 0.75, fbm(surfacePoint * 4.0 + float3(time * 0.002, 0, 0) + 30.0, 6));
            float light = dot(normal, sun);
            float day = smoothstep(-0.08, 0.25, light);
            float3 lit = mix(ground, float3(0.95), clouds * 0.85) * max(light, 0.0) * 1.3;
            float cities = land * (1.0 - day) * smoothstep(0.70, 0.78, fbm(surfacePoint * 60.0, 3)) * (1.0 - clouds);
            float3 night = float3(1.0, 0.6, 0.25) * cities * 0.25;
            float fresnel = pow(1.0 - lz, 3.0);
            float3 haze = float3(0.25, 0.5, 1.0) * fresnel * (0.1 + 1.2 * day);
            color = lit + night + haze;
            coverage = 1;
        }
        float3 rimDirection = normalize(dir - center * dot(dir, center));
        float sunSide = 0.2 + 1.3 * saturate(dot(rimDirection, sun) * 0.5 + 0.5);
        float halo = exp(-max(angle - radius, 0.0) / 0.018) * step(radius, angle);
        color += float3(0.3, 0.55, 1.0) * halo * sunSide * 0.9;
        return float4(color, coverage);
    }

    static float4 rings(float3 dir, float planetCoverage) {
        float3 center = normalize(float3(-0.30, -0.50, -0.81)) * 10.0;
        float planetRadiusWorld = 10.0 * sin(0.30);
        float3 normal = normalize(float3(0.15, 0.95, 0.25));
        float denom = dot(dir, normal);
        if (abs(denom) < 1e-4) { return float4(0); }
        float t = dot(center, normal) / denom;
        if (t <= 0) { return float4(0); }
        float3 hit = dir * t;
        float r = length(hit - center) / planetRadiusWorld;
        if (r < 1.45 || r > 2.3) { return float4(0); }
        float bands = valueNoise(float3(r * 40.0, 0.5, 0.5)) * 0.6 + valueNoise(float3(r * 160.0, 1.5, 0.5)) * 0.4;
        float gap = 1.0 - 0.85 * exp(-pow((r - 1.92) / 0.025, 2.0));
        float alpha = smoothstep(1.45, 1.55, r) * smoothstep(2.3, 2.15, r) * (0.10 + 0.45 * bands) * gap;
        float behindPlanet = step(length(center), t) * planetCoverage;
        alpha *= 1.0 - behindPlanet;
        float3 sun = normalize(sunDirection);
        float light = 0.35 + 0.65 * saturate(dot(normalize(hit - center), sun) * 0.5 + 0.5);
        float3 tint = mix(float3(0.78, 0.70, 0.60), float3(0.62, 0.66, 0.74), valueNoise(float3(r * 12.0, 3.0, 0.0)));
        return float4(tint * light * 0.8, alpha);
    }

    static float3 tonemap(float3 x) {
        return saturate((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14));
    }

    static float3 skyColor(float3 dir, float4 gas, float time, float breathing, float breathingVisibility) {
        float3 color = gas.rgb + stars(dir, time) * gas.a;
        color += sunGlow(dir);
        float4 planet = planetColor(dir, time);
        color = mix(color, planet.rgb, planet.a) + planet.rgb * (1.0 - planet.a);
        float4 ring = rings(dir, planet.a);
        color = mix(color, ring.rgb, ring.a);
        if (breathingVisibility > 0) {
            float fromForward = angleBetween(dir, float3(0, 0, -1));
            float radius = mix(0.05, 0.13, breathing);
            float ringLine = exp(-pow((fromForward - radius) / 0.006, 2.0));
            float fill = exp(-pow(fromForward / radius, 2.0)) * 0.12;
            color += float3(0.55, 0.85, 1.00) * (ringLine * 0.9 + fill) * breathingVisibility;
        }
        return tonemap(color * 0.9);
    }

    static float3 cubeFaceDirection(uint face, float2 uv) {
        float2 c = uv * 2 - 1;
        switch (face) {
            case 0: return float3(1, -c.y, -c.x);
            case 1: return float3(-1, -c.y, c.x);
            case 2: return float3(c.x, 1, c.y);
            case 3: return float3(c.x, -1, -c.y);
            case 4: return float3(c.x, -c.y, 1);
            default: return float3(-c.x, -c.y, -1);
        }
    }

    fragment float4 nebulaBakeFragment(SkyOut in [[stage_in]], constant uint &face [[buffer(0)]], constant float &size [[buffer(1)]]) {
        return nebula(normalize(cubeFaceDirection(face, in.position.xy / size)));
    }

    fragment float4 skyFragment(SkyOut in [[stage_in]],
                                constant SkyUniforms &u [[buffer(0)]],
                                texturecube<float> gasMap [[texture(0)]],
                                sampler s [[sampler(0)]]) {
        float4 world = u.inverseViewProjection * float4(in.ndc, 1, 1);
        float3 dir = normalize(world.xyz / world.w);
        float3 color = skyColor(dir, gasMap.sample(s, dir), u.params.x, u.params.z, u.params.w);
        return float4(color * u.params.y, 1);
    }
    """
}
