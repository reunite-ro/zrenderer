module resource.str;

import resource.base;

/// Keyframe of a STR layer. Type 0 keyframes contain absolute values while type 1 keyframes
/// contain the per frame delta that is applied to the preceding type 0 keyframe.
struct StrKeyframe
{
    int frame;
    uint type;
    float[2] pos = 0;
    float[8] uv = 0;
    float[8] xy = 0;
    float aniframe = 0;
    uint anitype;
    float delay = 0;
    float angle = 0; // 1024 units equal 360 degrees
    float[4] color = 0; // 0 - 255
    uint srcalpha; // D3DBLEND
    uint destalpha; // D3DBLEND
    uint mtpreset;
}

struct StrLayer
{
    string[] textures; // Relative to the directory of the str file, already converted to UTF-8
    StrKeyframe[] keyframes;
}

private enum StrHeaderSize = 4 + 4 * 4 + 16;
private enum StrKeyframeSize = 124;
private enum StrTextureNameSize = 128;
private enum StrVersion = 0x94;

class StrResource : BaseResource
{
    private string _baseDirectory;
    private string _relativeFilename;

    uint fps;
    uint maxKey;
    StrLayer[] layers;

    static immutable(string[]) fileExtensions = ["str"];
    static immutable(string) filePath = "texture/effect";

    /// filename is relative to data/texture/effect and does not include the extension
    this(string filename, string resourcePath)
    {
        import std.path : setExtension;

        super(filename, resourcePath, filePath, fileExtensions);
        this._baseDirectory = buildFilepath(resourcePath, filePath, "");
        this._relativeFilename = setExtension(filename, fileExtensions[0]);
    }

    /// Directory of the str file relative to data/texture/effect. Textures are relative to it.
    string textureDirectory() const pure nothrow @safe
    {
        import std.path : dirName;

        const dir = dirName(this._relativeFilename);
        return dir == "." ? "" : dir;
    }

    /// Duration of one playthrough in milliseconds
    float durationMs() const pure nothrow @safe @nogc
    {
        if (this.fps == 0)
        {
            return 0;
        }
        return this.maxKey * 1000f / this.fps;
    }

    override void load()
    {
        import resource.casepath : findPathCaseInsensitive;
        import std.exception : enforce, collectException, ErrnoException;
        import std.stdio : File;

        const path = findPathCaseInsensitive(this._baseDirectory, this._relativeFilename);
        enforce!ResourceException(path.length > 0, "Str file does not exist: " ~ this.filename);

        this._filename = path;

        File fileHandle;
        auto err = collectException!ErrnoException(File(path, "rb"), fileHandle);
        enforce!ResourceException(!err, err is null ? "" : err.msg);

        this.readData(fileHandle.rawRead(new ubyte[fileHandle.size()]));
        this._usable = true;
    }

    override void load(const(ubyte)[] buffer)
    {
        this.readData(buffer);
        this._usable = true;
    }

    private void readData(const(ubyte)[] buffer)
    {
        import std.exception : enforce;

        void require(ulong offset, ulong size)
        {
            enforce!ResourceException(offset + size <= buffer.length,
                    "Str file: '" ~ this.filename ~ "' is truncated.");
        }

        require(0, StrHeaderSize);
        enforce!ResourceException(buffer[0 .. 4] == ['S', 'T', 'R', 'M'],
                "Str file: '" ~ this.filename ~ "' does not have a valid signature.");

        ulong offset = 4;
        const ver = buffer.peekLE!uint(&offset);
        enforce!ResourceException(ver == StrVersion,
                "Str file: '" ~ this.filename ~ "' has an unsupported version.");

        this.fps = buffer.peekLE!uint(&offset);
        this.maxKey = buffer.peekLE!uint(&offset);
        const layerCount = buffer.peekLE!uint(&offset);
        offset += 16; // Reserved

        // Every layer needs at least 8 bytes. Guards against bogus allocations.
        enforce!ResourceException(layerCount <= (buffer.length - offset) / 8,
                "Str file: '" ~ this.filename ~ "' has an invalid layer count.");

        this.layers = new StrLayer[layerCount];

        foreach (ref layer; this.layers)
        {
            require(offset, 4);
            const textureCount = buffer.peekLE!int(&offset);
            enforce!ResourceException(textureCount >= 0, "Str file: '" ~ this.filename ~ "' has an invalid texture count.");
            require(offset, cast(ulong) textureCount * StrTextureNameSize);

            layer.textures = new string[textureCount];
            foreach (ref texture; layer.textures)
            {
                texture = decodeName(buffer[offset .. offset + StrTextureNameSize]);
                offset += StrTextureNameSize;
            }

            require(offset, 4);
            const keyframeCount = buffer.peekLE!int(&offset);
            enforce!ResourceException(keyframeCount >= 0, "Str file: '" ~ this.filename ~ "' has an invalid keyframe count.");
            require(offset, cast(ulong) keyframeCount * StrKeyframeSize);

            layer.keyframes = new StrKeyframe[keyframeCount];
            foreach (ref key; layer.keyframes)
            {
                key.frame = buffer.peekLE!int(&offset);
                key.type = buffer.peekLE!uint(&offset);
                foreach (ref v; key.pos) v = buffer.peekLE!float(&offset);
                foreach (ref v; key.uv) v = buffer.peekLE!float(&offset);
                foreach (ref v; key.xy) v = buffer.peekLE!float(&offset);
                key.aniframe = buffer.peekLE!float(&offset);
                key.anitype = buffer.peekLE!uint(&offset);
                key.delay = buffer.peekLE!float(&offset);
                key.angle = buffer.peekLE!float(&offset);
                foreach (ref v; key.color) v = buffer.peekLE!float(&offset);
                key.srcalpha = buffer.peekLE!uint(&offset);
                key.destalpha = buffer.peekLE!uint(&offset);
                key.mtpreset = buffer.peekLE!uint(&offset);
            }
        }

        // Some files contain garbage instead of the number of keys (e.g. efst_rabbit_aura/toto.str
        // contains the text "Fram"). Nothing is drawn after the last keyframe, so clamp to it.
        int lastFrame = 0;
        foreach (const layer; this.layers)
        {
            foreach (const key; layer.keyframes)
            {
                if (key.frame > lastFrame)
                {
                    lastFrame = key.frame;
                }
            }
        }

        const ulong usedKeys = cast(ulong) lastFrame + 1;
        if (this.maxKey > usedKeys + cast(ulong) this.fps * 10)
        {
            this.maxKey = cast(uint) usedKeys;
        }
    }
}

/// Converts a zero terminated Windows-949 encoded name to UTF-8 using '/' as separator
string decodeName(const(ubyte)[] raw)
{
    import std.algorithm.searching : countUntil;
    import std.array : replace;
    import std.utf : toUTF8;
    import zencoding.windows949 : fromWindows949;

    auto end = raw.countUntil(0);
    if (end < 0)
    {
        end = raw.length;
    }

    return fromWindows949(raw[0 .. end]).toUTF8.replace("\\", "/");
}

version (unittest)
{
    ubyte[] buildTestStr(uint fps, uint maxKey, string[] textures, StrKeyframe[] keys)
    {
        import std.bitmanip : nativeToLittleEndian;

        ubyte[] data = ['S', 'T', 'R', 'M'];
        data ~= nativeToLittleEndian(cast(uint) StrVersion);
        data ~= nativeToLittleEndian(fps);
        data ~= nativeToLittleEndian(maxKey);
        data ~= nativeToLittleEndian(1u);
        data ~= new ubyte[16];
        data ~= nativeToLittleEndian(cast(int) textures.length);
        foreach (texture; textures)
        {
            auto name = new ubyte[StrTextureNameSize];
            name[0 .. texture.length] = cast(const(ubyte)[]) texture;
            data ~= name;
        }
        data ~= nativeToLittleEndian(cast(int) keys.length);
        foreach (key; keys)
        {
            data ~= nativeToLittleEndian(key.frame);
            data ~= nativeToLittleEndian(key.type);
            foreach (v; key.pos) data ~= nativeToLittleEndian(v);
            foreach (v; key.uv) data ~= nativeToLittleEndian(v);
            foreach (v; key.xy) data ~= nativeToLittleEndian(v);
            data ~= nativeToLittleEndian(key.aniframe);
            data ~= nativeToLittleEndian(key.anitype);
            data ~= nativeToLittleEndian(key.delay);
            data ~= nativeToLittleEndian(key.angle);
            foreach (v; key.color) data ~= nativeToLittleEndian(v);
            data ~= nativeToLittleEndian(key.srcalpha);
            data ~= nativeToLittleEndian(key.destalpha);
            data ~= nativeToLittleEndian(key.mtpreset);
        }
        return data;
    }
}

unittest
{
    StrKeyframe key;
    key.frame = 3;
    key.type = 0;
    key.pos = [320, 300];
    key.xy = [-10, 10, 10, -10, -20, -20, 20, 20];
    key.color = [255, 128, 0, 200];
    key.angle = 256;
    key.srcalpha = 5;
    key.destalpha = 2;

    auto data = buildTestStr(60, 30, ["light\\glow.bmp"], [key]);

    auto str = new StrResource("test/effect", "");
    str.load(data);

    assert(str.usable);
    assert(str.fps == 60);
    assert(str.maxKey == 30);
    assert(str.layers.length == 1);
    assert(str.layers[0].textures == ["light/glow.bmp"]);
    assert(str.layers[0].keyframes.length == 1);
    assert(str.layers[0].keyframes[0] == key);
    assert(str.textureDirectory == "test");
    assert(str.durationMs == 500);

    import std.exception : assertThrown;

    // A bogus number of keys is clamped to the last keyframe
    auto bogus = buildTestStr(60, 0x6D617246, ["a.bmp"], [key]);
    auto bogusStr = new StrResource("bogus", "");
    bogusStr.load(bogus);
    assert(bogusStr.maxKey == 4);

    auto broken = new StrResource("broken", "");
    assertThrown!ResourceException(broken.load(data[0 .. $ - 10]));
    auto badSig = data.dup;
    badSig[0] = 'X';
    assertThrown!ResourceException(broken.load(badSig));
}
