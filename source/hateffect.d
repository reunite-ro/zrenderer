module hateffect;

import draw : Canvas, Color, RawImage;
import linearalgebra : Box, Vector2, Vector3;
import logging : LogLevel, LogDg;
import luad.state : LuaState;
import resource : ResourceManager, ResourceException, StrResource, StrKeyframe, StrLayer, TextureResource;
import sprite : Sprite, SpriteType;

/// Maximum number of hat effects per request
enum MaxHatEffects = 8;

/// Maximum number of frames an animation with hat effects may contain
enum MaxEffectFrames = 240;

/// Pixels per unit of hatEffectPos/hatEffectPosX (1/5 of a cell with 35 pixels per cell). The client adds
/// hatEffectPos to the height of the effect, so negative values move the effect down.
enum HatEffectUnitPx = 7f;

/// Str effects are authored around this point
enum StrCenter = 320f;

/// Maximum duration of a single animation frame when hat effects are drawn
private enum MaxStepMs = 50f;

/// Effect table shipped with zrenderer. Maps client effect ids (hatEffectID) to renderable resources.
enum HatEffectTableFile = "resolver_data/hat_effect_table.lua";

/// Sprite folder of effect sprites (이팩트)
private enum EffectSpriteFolder = "이팩트";

/// Lua helpers to access the hat effect tables in a flat way
enum HatEffectLuaHelpers = q{
    function __zr_HatEffectInfo(id)
        if hatEffectTable == nil then
            return nil
        end
        local t = hatEffectTable[id]
        if t == nil then
            return nil
        end
        return t.resourceFileName or "", t.hatEffectPos or 0, t.hatEffectPosX or 0,
            t.isRenderBeforeCharacter == true, t.isAttachedHead == true,
            t.hatEffectID or -1, t.isIgnoreRiding == true
    end

    function __zr_EffectTableCount(id)
        if ZrEffectTable == nil or ZrEffectTable[id] == nil then
            return 0
        end
        return #ZrEffectTable[id]
    end

    function __zr_EffectTableEntry(id, index)
        local e = ZrEffectTable[id][index]
        return e.type or "", e.file or "", e.behind == true, e.head == true,
            e.xOffset or 0, e.yOffset or 0, e.scale or 1
    end

    function __zr_HatEffectListing()
        local names = {}
        if HatEFID ~= nil then
            for k, v in pairs(HatEFID) do
                names[v] = k
            end
        end
        local ids = {}
        if hatEffectTable ~= nil then
            for id, _ in pairs(hatEffectTable) do
                if type(id) == "number" then
                    table.insert(ids, id)
                end
            end
        end
        table.sort(ids)
        local lines = {}
        for _, id in ipairs(ids) do
            table.insert(lines, id .. "\t" .. (names[id] or ""))
        end
        return table.concat(lines, "\n")
    end
};

// ------------------------------------------------------------------------------------------------
// Premultiplied float image used to compose effects and the character
// ------------------------------------------------------------------------------------------------

struct PremulImage
{
    uint width;
    uint height;
    float[] data; // r, g, b, a (premultiplied, 0..1)

    this(uint width, uint height) pure nothrow @safe
    {
        this.width = width;
        this.height = height;
        this.data = new float[cast(ulong) width * height * 4];
        this.data[] = 0;
    }

    /// Draws a straight alpha image with the same dimensions on top
    void over(const scope RawImage image) pure nothrow @safe @nogc
    {
        if (image.width != this.width || image.height != this.height)
        {
            return;
        }

        foreach (i, pixel; image.pixels)
        {
            if (pixel.a == 0)
            {
                continue;
            }
            const a = pixel.a / 255f;
            const inv = 1f - a;
            auto d = this.data[i * 4 .. i * 4 + 4];
            d[0] = pixel.r / 255f * a + d[0] * inv;
            d[1] = pixel.g / 255f * a + d[1] * inv;
            d[2] = pixel.b / 255f * a + d[2] * inv;
            d[3] = a + d[3] * inv;
        }
    }

    RawImage toRawImage() const pure nothrow @safe
    {
        // std.math.round is impure with the Microsoft C runtime. The values are clamped to 0..1.
        static ubyte round(float value) pure nothrow @safe @nogc
        {
            return cast(ubyte)(value + 0.5f);
        }

        RawImage image;
        image.width = this.width;
        image.height = this.height;
        image.pixels = new Color[cast(ulong) this.width * this.height];

        foreach (i, ref pixel; image.pixels)
        {
            const a = this.data[i * 4 + 3];
            if (a <= 0)
            {
                continue;
            }
            ubyte channel(float premul)
            {
                const v = premul / a;
                return round((v > 1 ? 1 : (v < 0 ? 0 : v)) * 255);
            }
            pixel.r = channel(this.data[i * 4]);
            pixel.g = channel(this.data[i * 4 + 1]);
            pixel.b = channel(this.data[i * 4 + 2]);
            pixel.a = round((a > 1 ? 1 : a) * 255);
        }

        return image;
    }
}

enum BlendMode
{
    over,
    plus
}

/// Maps the D3DBLEND destination factor of a str keyframe to a blend mode
BlendMode blendModeOf(uint destalpha) pure nothrow @safe @nogc
{
    switch (destalpha)
    {
    case 2: // D3DBLEND_ONE
    case 4: // D3DBLEND_INVSRCCOLOR
    case 7: // D3DBLEND_DESTALPHA: the client's back buffer has no alpha channel, so this is ONE
        return BlendMode.plus;
    default:
        return BlendMode.over;
    }
}

/**
  Blends a fragment into a premultiplied pixel.
  Params:
    d = Destination pixel (premultiplied)
    color = Fragment color (premultiplied by alpha)
    alpha = Fragment alpha
    srcalpha = D3DBLEND source factor
    mode = Blend mode derived from the destination factor
 */
void blendFragment(float[] d, const float[3] color, float alpha, uint srcalpha, BlendMode mode) pure nothrow @safe @nogc
{
    import std.algorithm.comparison : max, min;

    float[3] c = color;

    if (srcalpha == 2 && alpha > 0) // D3DBLEND_ONE: color is not weighted by alpha
    {
        c[] = color[] / alpha;
    }

    final switch (mode)
    {
    case BlendMode.plus:
        // Additive light. The emitted light also contributes coverage so that it
        // stays visible on transparent backgrounds.
        const coverage = max(c[0], max(c[1], c[2]));
        d[0] = min(1f, d[0] + c[0]);
        d[1] = min(1f, d[1] + c[1]);
        d[2] = min(1f, d[2] + c[2]);
        d[3] = min(1f, d[3] + coverage);
        break;
    case BlendMode.over:
        const inv = 1f - min(1f, alpha);
        d[0] = min(1f, c[0] + d[0] * inv);
        d[1] = min(1f, c[1] + d[1] * inv);
        d[2] = min(1f, c[2] + d[2] * inv);
        d[3] = min(1f, alpha + d[3] * inv);
        break;
    }
}

unittest
{
    import std.math : isClose;

    // Additive on a transparent background: light becomes coverage
    float[4] d = [0, 0, 0, 0];
    blendFragment(d[], [0.5f, 0.25f, 0], 0.5f, 5, BlendMode.plus);
    assert(isClose(d[0], 0.5f) && isClose(d[1], 0.25f) && isClose(d[3], 0.5f));

    // Additive on an opaque pixel is exact
    float[4] o = [0.2f, 0.2f, 0.2f, 1];
    blendFragment(o[], [0.5f, 0.25f, 0], 0.5f, 5, BlendMode.plus);
    assert(isClose(o[0], 0.7f) && isClose(o[1], 0.45f) && isClose(o[2], 0.2f) && isClose(o[3], 1));

    // Over
    float[4] v = [0, 0, 1, 1];
    blendFragment(v[], [0.5f, 0, 0], 0.5f, 5, BlendMode.over);
    assert(isClose(v[0], 0.5f) && isClose(v[2], 0.5f) && isClose(v[3], 1));
}

// ------------------------------------------------------------------------------------------------
// Str animation
// ------------------------------------------------------------------------------------------------

/// Evaluated state of a str layer at a given key
struct StrAnimState
{
    float[2] pos = 0;
    float[8] xy = 0;
    float angle = 0;
    float[4] color = 0;
    float aniframe = 0;
    uint srcalpha;
    uint destalpha;
}

/**
  Evaluates a layer at the given key (fractional frame).
  Type 0 keyframes set absolute values. A type 1 keyframe directly following a
  type 0 keyframe contains per-frame deltas that are applied until the next type 0 keyframe.
  A trailing type 0 keyframe without deltas ends layers that contain animated segments.
  Returns: false if the layer is not visible
 */
bool evaluateLayer(const scope StrLayer layer, float key, out StrAnimState state) pure nothrow @safe @nogc
{
    import std.math : floor;

    const keys = layer.keyframes;

    long baseIndex = -1;
    bool hasLaterBase = false;
    bool hasMorph = false;

    foreach (i, const k; keys)
    {
        if (k.type == 1)
        {
            hasMorph = true;
            continue;
        }
        if (k.type != 0)
        {
            continue;
        }
        if (k.frame <= key)
        {
            if (baseIndex < 0 || k.frame >= keys[baseIndex].frame)
            {
                baseIndex = i;
            }
        }
    }

    if (baseIndex < 0)
    {
        return false;
    }

    const base = keys[baseIndex];

    foreach (const k; keys)
    {
        if (k.type == 0 && k.frame > base.frame)
        {
            hasLaterBase = true;
            break;
        }
    }

    state.srcalpha = base.srcalpha;
    state.destalpha = base.destalpha;

    const bool morphs = baseIndex + 1 < keys.length && keys[baseIndex + 1].type == 1;

    if (!morphs)
    {
        if (!hasLaterBase && (hasMorph || key >= base.frame + 1))
        {
            return false;
        }

        state.pos = base.pos;
        state.xy = base.xy;
        state.angle = base.angle;
        state.color = base.color;
        state.aniframe = base.aniframe;
        return true;
    }

    const morph = keys[baseIndex + 1];
    const delta = key - base.frame;

    state.pos[] = base.pos[] + morph.pos[] * delta;
    state.xy[] = base.xy[] + morph.xy[] * delta;
    state.angle = base.angle + morph.angle * delta;
    state.color[] = base.color[] + morph.color[] * delta;

    const textureCount = cast(float) layer.textures.length;

    float positiveMod(float value, float divisor)
    {
        if (divisor <= 0)
        {
            return 0;
        }
        const m = value - divisor * floor(value / divisor);
        return m < divisor ? m : 0;
    }

    switch (morph.anitype)
    {
    case 1: // Normal
        state.aniframe = base.aniframe + morph.aniframe * delta;
        break;
    case 2: // Stop at the end
        const f = base.aniframe + morph.delay * delta;
        state.aniframe = f < textureCount - 1 ? f : textureCount - 1;
        break;
    case 3: // Repeat
        state.aniframe = positiveMod(base.aniframe + morph.delay * delta, textureCount);
        break;
    case 4: // Reverse repeat
        state.aniframe = positiveMod(base.aniframe - morph.delay * delta, textureCount);
        break;
    default:
        state.aniframe = base.aniframe;
        break;
    }

    return true;
}

unittest
{
    import std.math : isClose;

    StrLayer layer;
    layer.textures = ["a.bmp", "b.bmp", "c.bmp"];

    StrKeyframe base;
    base.frame = 10;
    base.type = 0;
    base.pos = [320, 320];
    base.color = [255, 255, 255, 100];
    base.srcalpha = 5;
    base.destalpha = 2;

    StrKeyframe morph;
    morph.frame = 10;
    morph.type = 1;
    morph.pos = [2, -1];
    morph.color = [0, 0, 0, 10];
    morph.anitype = 3;
    morph.delay = 0.5;

    StrKeyframe end;
    end.frame = 20;
    end.type = 0;

    layer.keyframes = [base, morph, end];

    StrAnimState state;
    assert(!evaluateLayer(layer, 5, state)); // Before the first keyframe

    assert(evaluateLayer(layer, 14, state));
    assert(isClose(state.pos[0], 328) && isClose(state.pos[1], 316));
    assert(isClose(state.color[3], 140));
    assert(isClose(state.aniframe, 2)); // (0 + 0.5 * 4) % 3
    assert(state.srcalpha == 5 && state.destalpha == 2);

    assert(evaluateLayer(layer, 17, state));
    assert(isClose(state.aniframe, 0.5)); // 3.5 % 3

    assert(!evaluateLayer(layer, 21, state)); // Terminal keyframe ends the layer

    // Static layers without morphs are shown for one frame, or until the next keyframe
    StrLayer staticLayer;
    staticLayer.textures = ["a.bmp"];
    StrKeyframe s1;
    s1.frame = 0;
    StrKeyframe s2;
    s2.frame = 5;
    s2.aniframe = 0;
    staticLayer.keyframes = [s1, s2];
    assert(evaluateLayer(staticLayer, 3, state));
    assert(evaluateLayer(staticLayer, 5.5, state));
    assert(!evaluateLayer(staticLayer, 6, state));

    // Anitype 2 stops at the last texture, anitype 4 plays reversed
    morph.anitype = 2;
    morph.delay = 1;
    layer.keyframes = [base, morph, end];
    assert(evaluateLayer(layer, 19, state));
    assert(isClose(state.aniframe, 2));
    morph.anitype = 4;
    layer.keyframes = [base, morph, end];
    assert(evaluateLayer(layer, 11, state));
    assert(isClose(state.aniframe, 2));
}

/// Screen space corners (top left, top right, bottom right, bottom left) of an evaluated layer
Vector2[4] quadCorners(const scope StrAnimState state, Vector2 anchor) pure nothrow @safe @nogc
{
    import std.math : cos, sin, PI;

    // Positive angles rotate clockwise on screen. 1024 units are a full rotation.
    const radians = state.angle * PI * 2 / 1024;
    const c = cos(radians);
    const s = sin(radians);

    const tx = state.pos[0] - StrCenter + anchor.x;
    const ty = state.pos[1] - StrCenter + anchor.y;

    Vector2[4] corners;
    static immutable ubyte[4] order = [0, 1, 2, 3];
    foreach (i; order)
    {
        const x = state.xy[i];
        const y = state.xy[i + 4];
        corners[i] = Vector2(x * c - y * s + tx, x * s + y * c + ty);
    }

    return corners;
}

unittest
{
    import std.math : isClose;

    StrAnimState state;
    state.pos = [330, 300];
    state.xy = [-5, 5, 5, -5, -10, -10, 10, 10];

    auto corners = quadCorners(state, Vector2(100, 50));
    assert(isClose(corners[0].x, 105) && isClose(corners[0].y, 20));
    assert(isClose(corners[2].x, 115) && isClose(corners[2].y, 40));

    state.angle = 256; // 90 degrees clockwise
    corners = quadCorners(state, Vector2(0, 0));
    // Top left (-5, -10) rotated clockwise by 90 degrees becomes (10, -5)
    assert(isClose(corners[0].x, 10 + 10, 1e-4) && isClose(corners[0].y, -5 - 20, 1e-4));
}

/// Texture converted to premultiplied floats (r, g, b, a) for fast sampling
struct PremulTexture
{
    uint width;
    uint height;
    float[] data;

    this(const scope RawImage image) pure nothrow @safe
    {
        this.width = image.width;
        this.height = image.height;
        this.data = new float[image.pixels.length * 4];

        foreach (i, pixel; image.pixels)
        {
            const a = pixel.a / 255f;
            this.data[i * 4] = pixel.r / 255f * a;
            this.data[i * 4 + 1] = pixel.g / 255f * a;
            this.data[i * 4 + 2] = pixel.b / 255f * a;
            this.data[i * 4 + 3] = a;
        }
    }

    bool empty() const pure nothrow @safe @nogc
    {
        return this.width == 0 || this.height == 0;
    }
}

/// Samples a texture bilinearly with clamped edges. Returns premultiplied color and alpha.
private void sampleBilinear(const scope PremulTexture texture, float u, float v,
        out float[3] color, out float alpha) pure nothrow @trusted @nogc
{
    const fx = u * texture.width - 0.5f;
    const fy = v * texture.height - 0.5f;

    // floor() without the function call overhead
    long x0 = cast(long) fx;
    long y0 = cast(long) fy;
    if (fx < x0) x0 -= 1;
    if (fy < y0) y0 -= 1;

    const tx = fx - x0;
    const ty = fy - y0;

    const maxX = cast(long) texture.width - 1;
    const maxY = cast(long) texture.height - 1;

    long x1 = x0 + 1, y1 = y0 + 1;
    x0 = x0 < 0 ? 0 : (x0 > maxX ? maxX : x0);
    x1 = x1 < 0 ? 0 : (x1 > maxX ? maxX : x1);
    y0 = y0 < 0 ? 0 : (y0 > maxY ? maxY : y0);
    y1 = y1 < 0 ? 0 : (y1 > maxY ? maxY : y1);

    const w00 = (1 - tx) * (1 - ty);
    const w10 = tx * (1 - ty);
    const w01 = (1 - tx) * ty;
    const w11 = tx * ty;

    // Indices are clamped to the texture dimensions above
    const d = texture.data.ptr;
    const p00 = d + (y0 * texture.width + x0) * 4;
    const p10 = d + (y0 * texture.width + x1) * 4;
    const p01 = d + (y1 * texture.width + x0) * 4;
    const p11 = d + (y1 * texture.width + x1) * 4;

    color[0] = p00[0] * w00 + p10[0] * w10 + p01[0] * w01 + p11[0] * w11;
    color[1] = p00[1] * w00 + p10[1] * w10 + p01[1] * w01 + p11[1] * w11;
    color[2] = p00[2] * w00 + p10[2] * w10 + p01[2] * w01 + p11[2] * w11;
    alpha = p00[3] * w00 + p10[3] * w10 + p01[3] * w01 + p11[3] * w11;
}

/**
  Rasterizes a textured quad. Corners are top left, top right, bottom right, bottom left.
  The quad is split into two triangles like the client does. Every pixel is drawn at most once.
  Params:
    color = Keyframe color, 0..1
 */
void drawQuad(ref PremulImage dst, const scope PremulTexture texture, const scope Vector2[4] corners,
        const scope float[4] color, uint srcalpha, BlendMode mode) pure nothrow @safe @nogc
{
    import std.algorithm.comparison : max, min;
    import std.math : floor, ceil;

    if (texture.empty || color[3] <= 0)
    {
        return;
    }

    static immutable float[2][4] uvs = [[0, 0], [1, 0], [1, 1], [0, 1]];
    static immutable ubyte[3][2] triangles = [[0, 1, 3], [1, 2, 3]];

    float minX = float.max, minY = float.max, maxX = -float.max, maxY = -float.max;
    foreach (c; corners)
    {
        minX = min(minX, c.x);
        minY = min(minY, c.y);
        maxX = max(maxX, c.x);
        maxY = max(maxY, c.y);
    }

    const startX = max(0, cast(long) floor(minX));
    const startY = max(0, cast(long) floor(minY));
    const endX = min(cast(long) dst.width - 1, cast(long) ceil(maxX));
    const endY = min(cast(long) dst.height - 1, cast(long) ceil(maxY));

    if (startX > endX || startY > endY)
    {
        return;
    }

    // Barycentric weights and texture coordinates are linear functions of the pixel position.
    // Coefficients per triangle: value = c[0] * x + c[1] * y + c[2]
    struct Triangle
    {
        bool valid;
        float[3] w0;
        float[3] w1;
        float[3] u;
        float[3] v;
    }

    Triangle[2] tris;

    foreach (t, tri; triangles)
    {
        const a = corners[tri[0]], b = corners[tri[1]], c = corners[tri[2]];
        const area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
        if (area > -1e-6f && area < 1e-6f)
        {
            continue;
        }

        const inv = 1f / area;
        auto tr = &tris[t];
        tr.valid = true;
        tr.w0 = [(b.y - c.y) * inv, (c.x - b.x) * inv, (b.x * c.y - b.y * c.x) * inv];
        tr.w1 = [(c.y - a.y) * inv, (a.x - c.x) * inv, (c.x * a.y - c.y * a.x) * inv];

        const ua = uvs[tri[0]], ub = uvs[tri[1]], uc = uvs[tri[2]];
        foreach (k; 0 .. 3)
        {
            // w2 = 1 - w0 - w1
            const w2k = (k == 2 ? 1f : 0f) - tr.w0[k] - tr.w1[k];
            tr.u[k] = tr.w0[k] * ua[0] + tr.w1[k] * ub[0] + w2k * uc[0];
            tr.v[k] = tr.w0[k] * ua[1] + tr.w1[k] * ub[1] + w2k * uc[1];
        }
    }

    for (long y = startY; y <= endY; ++y)
    {
        const py = y + 0.5f;

        for (long x = startX; x <= endX; ++x)
        {
            const px = x + 0.5f;

            foreach (ref tr; tris)
            {
                if (!tr.valid)
                {
                    continue;
                }

                const w0 = tr.w0[0] * px + tr.w0[1] * py + tr.w0[2];
                const w1 = tr.w1[0] * px + tr.w1[1] * py + tr.w1[2];

                if (w0 < 0 || w1 < 0 || w0 + w1 > 1)
                {
                    continue;
                }

                const u = tr.u[0] * px + tr.u[1] * py + tr.u[2];
                const v = tr.v[0] * px + tr.v[1] * py + tr.v[2];

                float[3] texel;
                float texelAlpha;
                sampleBilinear(texture, u, v, texel, texelAlpha);

                const alpha = texelAlpha * color[3];
                float[3] fragment = [texel[0] * color[0] * color[3],
                    texel[1] * color[1] * color[3],
                    texel[2] * color[2] * color[3]];

                // Transparent or black fragments are discarded like the client does
                if (alpha <= 0 || (fragment[0] + fragment[1] + fragment[2]) < 1f / 1024)
                {
                    break;
                }

                const index = (cast(ulong) y * dst.width + x) * 4;
                blendFragment(dst.data[index .. index + 4], fragment, alpha, srcalpha, mode);
                break;
            }
        }
    }
}

unittest
{
    RawImage white;
    white.width = 2;
    white.height = 2;
    white.pixels = [Color(0xFFFFFFFF), Color(0xFFFFFFFF), Color(0xFFFFFFFF), Color(0xFFFFFFFF)];
    const texture = PremulTexture(white);

    auto img = PremulImage(10, 10);
    Vector2[4] corners = [Vector2(2, 3), Vector2(6, 3), Vector2(6, 8), Vector2(2, 8)];
    img.drawQuad(texture, corners, [1, 1, 1, 1], 5, BlendMode.plus);

    uint covered = 0;
    foreach (y; 0 .. 10)
    {
        foreach (x; 0 .. 10)
        {
            const inside = x >= 2 && x < 6 && y >= 3 && y < 8;
            const a = img.data[(y * 10 + x) * 4 + 3];
            if (inside)
            {
                assert(a > 0.99f); // Drawn exactly once, no double blending on the diagonal
                assert(img.data[(y * 10 + x) * 4] <= 1f);
                covered++;
            }
            else
            {
                assert(a == 0);
            }
        }
    }
    assert(covered == 20);

    // Additive blending twice brightens but never exceeds coverage
    auto half = PremulImage(10, 10);
    half.drawQuad(texture, corners, [0.5f, 0.5f, 0.5f, 1], 5, BlendMode.plus);
    const firstPass = half.data[(4 * 10 + 3) * 4];
    half.drawQuad(texture, corners, [0.5f, 0.5f, 0.5f, 1], 5, BlendMode.plus);
    assert(half.data[(4 * 10 + 3) * 4] > firstPass);
}

// ------------------------------------------------------------------------------------------------
// Effect layers
// ------------------------------------------------------------------------------------------------

/// A renderable effect. Coordinates are relative to the character's feet.
interface EffectLayer
{
    /// Bounding box over the whole animation
    Box bounds();
    /// Whether the effect is drawn behind the character
    bool behind() const;
    /// Duration of one loop in milliseconds. 0 if the effect is static.
    float loopMs() const;
    /// Point in time that should be used when only a single frame is drawn
    float representativeMs();
    /// Draws the effect. origin is the pixel position of the character's feet.
    void draw(ref PremulImage dst, float ms, Vector2 origin);
}

class StrEffectLayer : EffectLayer
{
    private
    {
        StrResource _str;
        PremulTexture[][] _textures; // Per layer per texture index
        Vector2 _anchor;
        bool _behind;
    }

    this(StrResource str, PremulTexture[][] textures, Vector2 anchor, bool behind)
    {
        this._str = str;
        this._textures = textures;
        this._anchor = anchor;
        this._behind = behind;
    }

    bool behind() const
    {
        return this._behind;
    }

    float loopMs() const
    {
        return this._str.durationMs;
    }

    Box bounds()
    {
        import std.algorithm.comparison : max, min;
        import std.math : ceil, floor;

        float minX = float.max, minY = float.max, maxX = -float.max, maxY = -float.max;

        foreach (key; 0 .. this._str.maxKey)
        {
            foreach (l, const layer; this._str.layers)
            {
                StrAnimState state;
                if (!evaluateLayer(layer, key, state) || !this.hasTexture(l, state))
                {
                    continue;
                }
                foreach (corner; quadCorners(state, this._anchor))
                {
                    minX = min(minX, corner.x);
                    minY = min(minY, corner.y);
                    maxX = max(maxX, corner.x);
                    maxY = max(maxY, corner.y);
                }
            }
        }

        if (minX > maxX)
        {
            return Box.init;
        }

        return Box(cast(int) floor(minX), cast(int) floor(minY), cast(int) ceil(maxX), cast(int) ceil(maxY));
    }

    float representativeMs()
    {
        if (this._str.fps == 0)
        {
            return 0;
        }

        uint bestKey = 0;
        float bestScore = 0;

        foreach (key; 0 .. this._str.maxKey)
        {
            float score = 0;
            foreach (l, const layer; this._str.layers)
            {
                StrAnimState state;
                if (evaluateLayer(layer, key, state) && this.hasTexture(l, state))
                {
                    score += state.color[3] > 0 ? state.color[3] : 0;
                }
            }
            if (score > bestScore)
            {
                bestScore = score;
                bestKey = key;
            }
        }

        return bestKey * 1000f / this._str.fps;
    }

    void draw(ref PremulImage dst, float ms, Vector2 origin)
    {
        import std.math : fmod;

        if (this._str.fps == 0 || this._str.maxKey == 0)
        {
            return;
        }

        const key = fmod(ms / 1000f * this._str.fps, cast(float) this._str.maxKey);
        const anchor = Vector2(origin.x + this._anchor.x, origin.y + this._anchor.y);

        foreach (l, const layer; this._str.layers)
        {
            StrAnimState state;
            if (!evaluateLayer(layer, key, state) || !this.hasTexture(l, state))
            {
                continue;
            }

            float[4] color = [clamp01(state.color[0] / 255f), clamp01(state.color[1] / 255f),
                clamp01(state.color[2] / 255f), clamp01(state.color[3] / 255f)];

            dst.drawQuad(this.texture(l, state), quadCorners(state, anchor), color,
                    state.srcalpha, blendModeOf(state.destalpha));
        }
    }

    private bool hasTexture(ulong layer, const scope StrAnimState state) const pure nothrow @safe @nogc
    {
        return !this.texture(layer, state).empty;
    }

    private const(PremulTexture) texture(ulong layer, const scope StrAnimState state) const pure nothrow @safe @nogc
    {
        if (layer >= this._textures.length || this._textures[layer].length == 0)
        {
            return PremulTexture.init;
        }
        long index = cast(long) state.aniframe;
        if (index < 0)
        {
            index = 0;
        }
        if (index >= this._textures[layer].length)
        {
            index = this._textures[layer].length - 1;
        }
        return this._textures[layer][index];
    }
}

private float clamp01(float value) pure nothrow @safe @nogc
{
    return value < 0 ? 0 : (value > 1 ? 1 : value);
}

class SprEffectLayer : EffectLayer
{
    private
    {
        Sprite _sprite;
        Vector2 _anchor;
        bool _behind;
    }

    this(Sprite sprite, Vector2 anchor, bool behind)
    {
        this._sprite = sprite;
        this._anchor = anchor;
        this._behind = behind;
    }

    bool behind() const
    {
        return this._behind;
    }

    private float frameMs() const
    {
        const interval = this._sprite.act.action(0).interval;
        return (interval > 0 ? interval : 4) * 25f;
    }

    float loopMs() const
    {
        return this._sprite.act.numberOfFrames(0) * this.frameMs();
    }

    float representativeMs()
    {
        return 0;
    }

    Box bounds()
    {
        auto box = this._sprite.drawObjectsOfAction(0).boundingBox;
        if (box.isInfinite || (box.width == 0 && box.height == 0))
        {
            return Box.init;
        }
        const ax = cast(int) this._anchor.x;
        const ay = cast(int) this._anchor.y;
        return Box(box.x1 + ax, box.y1 + ay, box.x2 + ax, box.y2 + ay);
    }

    void draw(ref PremulImage dst, float ms, Vector2 origin)
    {
        import renderer : drawFrameOnImage;
        import draw : DrawObject;

        const frames = this._sprite.act.numberOfFrames(0);
        if (frames == 0)
        {
            return;
        }

        const frame = cast(uint) ((cast(ulong) (ms / this.frameMs())) % frames);
        auto frameobj = this._sprite.drawObjectsOfFrame(0, frame);
        if (frameobj == DrawObject.init)
        {
            return;
        }

        RawImage layer;
        layer.width = dst.width;
        layer.height = dst.height;
        layer.pixels = new Color[cast(ulong) dst.width * dst.height];

        const offset = Vector3(-(origin.x + this._anchor.x), -(origin.y + this._anchor.y), 0);
        drawFrameOnImage(layer, this._sprite, 0, frame, frameobj, offset);

        dst.over(layer);
    }
}

// ------------------------------------------------------------------------------------------------
// Loading
// ------------------------------------------------------------------------------------------------

struct HatEffects
{
    EffectLayer[] layers;
    float scale = 1; // Size modifier of the character (e.g. EF_GIANTBODY2)
}

/// Information of a hat effect as defined in hateffectinfo
struct HatEffectInfo
{
    bool exists;
    string resourceFileName; // UTF-8, relative to data/texture/effect, '/' separated
    float pos = 0;
    float posX = 0;
    bool renderBefore;
    bool attachedHead;
    int effectId = -1;
    bool ignoreRiding;
}

/**
  Extra height of a mounted character in units of HatEffectUnitPx, as the client defines it.
  Hat effects are raised by it unless they ignore riding or are attached to the head.
 */
int ridingHeight(uint jobid) pure nothrow @safe @nogc
{
    import resolver : isDoram;

    switch (jobid)
    {
    case 13, 21, 4014, 4022, 4036, 4044: // Peco Peco
        return 3;
    case 4080: .. case 4095: // Dragon, Gryphon, Warg and Mado Gear
    case 4109: .. case 4112:
    case 4278: .. case 4281:
        return 5;
    case 4265: .. case 4277: // Costume mounts, dorams are not raised
    case 4309: .. case 4315:
    case 4358: .. case 4360:
        return isDoram(jobid) ? 0 : 5;
    default:
        return 0;
    }
}

unittest
{
    assert(ridingHeight(4008) == 0); // Lord Knight
    assert(ridingHeight(4014) == 3); // Lord Knight on a Peco Peco
    assert(ridingHeight(4080) == 5); // Rune Knight on a dragon
    assert(ridingHeight(4265) == 5); // Dragon Knight on a costume mount
    assert(ridingHeight(4315) == 0); // Spirit Handler on a costume mount
}

/// Converts a Windows-949 string coming from the client lua files to a UTF-8 path
private string clientPathToUtf8(string raw)
{
    import std.array : replace;
    import std.string : representation;
    import std.utf : toUTF8;
    import zencoding.windows949 : fromWindows949;

    return fromWindows949(raw.representation).toUTF8.replace("\\", "/");
}

HatEffectInfo hatEffectInfo(uint id, ref LuaState L)
{
    import luad.base : LuaObject;
    import luad.error : LuaErrorException;
    import luad.lfunction : LuaFunction;

    HatEffectInfo info;

    try
    {
        auto func = L.get!LuaFunction("__zr_HatEffectInfo");
        scope LuaObject[] ret = func(id);

        // Release the references while the lua state is alive. Otherwise the GC may
        // finalize them after the state has been closed.
        scope (exit) foreach (ref value; ret) destroy(value);

        if (ret.length < 7 || ret[0].isNil)
        {
            return info;
        }

        info.exists = true;
        info.resourceFileName = clientPathToUtf8(ret[0].to!string);
        info.pos = ret[1].to!float;
        info.posX = ret[2].to!float;
        info.renderBefore = ret[3].to!bool;
        info.attachedHead = ret[4].to!bool;
        info.effectId = ret[5].to!int;
        info.ignoreRiding = ret[6].to!bool;
    }
    catch (LuaErrorException err)
    {
        // Treat as non existent
    }

    return info;
}

/// Entry of the effect table (resolver_data/hat_effect_table.lua)
struct EffectTableEntry
{
    string type;
    string file;
    bool behind;
    bool head;
    float xOffset = 0;
    float yOffset = 0;
    float scale = 1;
}

EffectTableEntry[] effectTableEntries(int effectId, ref LuaState L)
{
    import luad.base : LuaObject;
    import luad.error : LuaErrorException;
    import luad.lfunction : LuaFunction;
    import std.uni : toUpper;

    EffectTableEntry[] entries;

    try
    {
        auto count = L.get!LuaFunction("__zr_EffectTableCount").call!int(effectId);
        auto entryFunc = L.get!LuaFunction("__zr_EffectTableEntry");

        foreach (i; 1 .. count + 1)
        {
            scope LuaObject[] ret = entryFunc(effectId, i);
            scope (exit) foreach (ref value; ret) destroy(value);
            if (ret.length < 7)
            {
                continue;
            }

            EffectTableEntry entry;
            entry.type = toUpper(ret[0].to!string);
            entry.file = ret[1].to!string;
            entry.behind = ret[2].to!bool;
            entry.head = ret[3].to!bool;
            entry.xOffset = ret[4].to!float;
            entry.yOffset = ret[5].to!float;
            entry.scale = ret[6].to!float;
            entries ~= entry;
        }
    }
    catch (LuaErrorException err)
    {
        // No entries
    }

    return entries;
}

/// Throws: ResourceException
private StrEffectLayer loadStrLayer(string file, Vector2 anchor, bool behind, ResourceManager resManager, LogDg log)
{
    import std.path : buildPath, stripExtension;

    auto str = resManager.get!StrResource(stripExtension(file));
    str.load();

    PremulTexture[string] cache;
    auto textures = new PremulTexture[][str.layers.length];

    foreach (l, const layer; str.layers)
    {
        textures[l] = new PremulTexture[layer.textures.length];
        foreach (t, name; layer.textures)
        {
            if (auto cached = name in cache)
            {
                textures[l][t] = *cached;
                continue;
            }

            PremulTexture image;
            string error;
            // Textures are relative to the str file. Some str files (e.g. 2023RTC_S_Robe1/gold1.str)
            // use textures that only exist in data/texture/effect itself.
            const candidates = str.textureDirectory.length > 0
                ? [buildPath(str.textureDirectory, name), name] : [name];
            foreach (candidate; candidates)
            {
                try
                {
                    auto texture = resManager.get!TextureResource(candidate);
                    texture.load();
                    image = PremulTexture(texture.image);
                    break;
                }
                catch (ResourceException err)
                {
                    if (error.length == 0)
                    {
                        error = err.msg;
                    }
                }
            }
            if (image.empty && error.length > 0)
            {
                log(LogLevel.warning, error);
            }

            cache[name] = image;
            textures[l][t] = image;
        }
    }

    return new StrEffectLayer(str, textures, anchor, behind);
}

/// Throws: ResourceException
private SprEffectLayer loadSprLayer(string file, Vector2 anchor, bool behind, ResourceManager resManager)
{
    import std.path : buildPath;

    auto sprite = resManager.getSprite(buildPath(EffectSpriteFolder, file), SpriteType.standard);
    sprite.loadImagesOfAction(0);

    return new SprEffectLayer(sprite, anchor, behind);
}

/**
  Loads the given hat effects.
  Params:
    ids = Hat effect ids (HatEFID)
    jobid = Job of the character. Mounts and dorams change the height of the effects.
 */
HatEffects loadHatEffects(const scope uint[] ids, uint jobid,
        ref LuaState L, ResourceManager resManager, LogDg log)
{
    import resolver : isDoram;
    import std.format : format;

    HatEffects effects;

    foreach (id; ids)
    {
        const info = hatEffectInfo(id, L);
        if (!info.exists)
        {
            log(LogLevel.warning, format("Hat effect %d does not exist in hateffectinfo", id));
            continue;
        }

        // The client adds hatEffectPos to the height of the effect, so negative values move it down.
        // The str files of attached head effects are already authored at head height, the client
        // does not move them to the head. They are lowered for dorams and ignore mounts instead.
        float height = info.pos;
        if (!info.ignoreRiding && !info.attachedHead)
        {
            height += ridingHeight(jobid);
        }
        if (info.attachedHead && isDoram(jobid))
        {
            height -= 3;
        }

        Vector2 anchor = Vector2(info.posX * HatEffectUnitPx, -height * HatEffectUnitPx);

        if (info.resourceFileName.length > 0)
        {
            try
            {
                log(LogLevel.trace, "Loading Hat Effect " ~ info.resourceFileName);
                effects.layers ~= loadStrLayer(info.resourceFileName, anchor, info.renderBefore, resManager, log);
            }
            catch (ResourceException err)
            {
                log(LogLevel.warning, err.msg);
            }
        }

        if (info.effectId < 0)
        {
            continue;
        }

        auto entries = effectTableEntries(info.effectId, L);
        if (entries.length == 0)
        {
            log(LogLevel.warning, format("Hat effect %d uses client effect %d which has no entry in %s. " ~
                    "Run hateffecttool to find candidate files.", id, info.effectId, HatEffectTableFile));
            continue;
        }

        foreach (entry; entries)
        {
            const entryAnchor = Vector2(anchor.x + entry.xOffset,
                    anchor.y + entry.yOffset + (entry.head ? -100 : 0));
            try
            {
                switch (entry.type)
                {
                case "STR":
                    log(LogLevel.trace, "Loading Effect " ~ entry.file);
                    effects.layers ~= loadStrLayer(entry.file, entryAnchor,
                            entry.behind || info.renderBefore, resManager, log);
                    break;
                case "SPR":
                    log(LogLevel.trace, "Loading Effect Sprite " ~ entry.file);
                    effects.layers ~= loadSprLayer(entry.file, entryAnchor,
                            entry.behind || info.renderBefore, resManager);
                    break;
                case "SCALE":
                    effects.scale *= entry.scale > 0 ? entry.scale : 1;
                    break;
                default:
                    log(LogLevel.warning, format("Unknown effect table type \"%s\" for effect %d", entry.type, info.effectId));
                    break;
                }
            }
            catch (ResourceException err)
            {
                log(LogLevel.warning, err.msg);
            }
        }
    }

    return effects;
}

// ------------------------------------------------------------------------------------------------
// Composition
// ------------------------------------------------------------------------------------------------

struct EffectTimeline
{
    uint steps = 1; // Number of output frames
    uint stepsPerBodyFrame = 1;
    float stepMs = 0; // Exact duration of one output frame
    ushort delayMs = 0; // Rounded duration used for the animation
}

/**
  Creates a timeline that covers at least one full loop of the longest effect.
  The body animation is repeated and every body frame is shown for the same
  amount of output frames so that its timing is preserved.
 */
EffectTimeline createTimeline(ulong bodyFrames, float bodyFrameMs, const scope EffectLayer[] layers)
{
    import std.algorithm.comparison : max, min;
    import std.math : ceil, round;

    EffectTimeline timeline;

    if (bodyFrames == 0)
    {
        bodyFrames = 1;
    }
    if (!(bodyFrameMs > 0))
    {
        bodyFrameMs = 100;
    }

    float longestLoop = 0;
    foreach (layer; layers)
    {
        longestLoop = max(longestLoop, layer.loopMs());
    }

    // Only split body frames when there is an animated effect
    const m = longestLoop > 0 ? max(1u, cast(uint) ceil(bodyFrameMs / MaxStepMs)) : 1u;
    const cycleMs = bodyFrames * bodyFrameMs;
    const cycles = max(1UL, cast(ulong) ceil(longestLoop / cycleMs));

    timeline.stepsPerBodyFrame = m;
    timeline.stepMs = bodyFrameMs / m;
    timeline.delayMs = cast(ushort) max(1, min(ushort.max, round(timeline.stepMs)));
    timeline.steps = cast(uint) min(cast(ulong) MaxEffectFrames, m * bodyFrames * cycles);

    return timeline;
}

unittest
{
    // Body: 8 frames at 100ms. Effect loop: 2000ms.
    class FakeLayer : EffectLayer
    {
        Box bounds() { return Box.init; }
        bool behind() const { return false; }
        float loopMs() const { return 2000; }
        float representativeMs() { return 0; }
        void draw(ref PremulImage dst, float ms, Vector2 origin) {}
    }

    auto timeline = createTimeline(8, 100, [new FakeLayer]);
    assert(timeline.stepsPerBodyFrame == 2); // 100ms split into steps of at most 50ms
    assert(timeline.delayMs == 50);
    assert(timeline.steps == 2 * 8 * 3); // 3 body cycles cover 2000ms

    auto capped = createTimeline(1, 25, [new FakeLayer]);
    assert(capped.steps == 80); // 2000ms / 25ms
    auto noEffects = createTimeline(4, 100, []);
    assert(noEffects.steps == 4);
}

/// Returns the union of all effect bounds
Box effectBounds(EffectLayer[] layers)
{
    Box box;
    box.toInfinity();

    foreach (layer; layers)
    {
        const b = layer.bounds();
        if (b != Box.init)
        {
            box.updateBounds(b);
        }
    }

    return box;
}

/**
  Draws the effects behind and in front of the character frames.
  Params:
    character = Rendered character frames. All frames must have the canvas dimensions.
    canvas = Canvas the character frames were rendered onto
    single = Only a single frame is requested. Effects use their representative frame.
 */
RawImage[] composeFrames(const scope RawImage[] character, EffectLayer[] layers,
        const scope Canvas canvas, const scope EffectTimeline timeline, bool single)
{
    const origin = Vector2(canvas.originx, canvas.originy);
    const steps = single ? 1 : timeline.steps;

    RawImage[] output = new RawImage[steps];

    auto buffer = PremulImage(canvas.width, canvas.height);

    foreach (s; 0 .. steps)
    {
        buffer.data[] = 0;

        float ms(EffectLayer layer)
        {
            return single ? layer.representativeMs() : s * timeline.stepMs;
        }

        foreach (layer; layers)
        {
            if (layer.behind)
            {
                layer.draw(buffer, ms(layer), origin);
            }
        }

        if (character.length > 0)
        {
            const bodyIndex = single ? 0 : (s / timeline.stepsPerBodyFrame) % character.length;
            buffer.over(character[bodyIndex]);
        }

        foreach (layer; layers)
        {
            if (!layer.behind)
            {
                layer.draw(buffer, ms(layer), origin);
            }
        }

        output[s] = buffer.toRawImage();
    }

    return output;
}
