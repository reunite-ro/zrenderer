module resource.texture;

import resource.base;
import draw : Color, RawImage;

/// Texture used by effects (STR). Supports BMP (magenta is transparent) and TGA.
class TextureResource : BaseResource
{
    private string _baseDirectory;
    private string _relativeFilename;
    private RawImage _image;

    static immutable(string[]) fileExtensions = [];
    static immutable(string) filePath = "texture/effect";

    /// filename is relative to data/texture/effect and includes the extension
    this(string filename, string resourcePath)
    {
        super(filename, resourcePath, filePath, fileExtensions);
        this._baseDirectory = buildFilepath(resourcePath, filePath, "");
        this._relativeFilename = filename;
    }

    const(RawImage) image() const pure nothrow @safe @nogc
    {
        return this._image;
    }

    override void load()
    {
        import resource.casepath : findPathCaseInsensitive;
        import std.exception : enforce, collectException, ErrnoException;
        import std.stdio : File;

        const path = findPathCaseInsensitive(this._baseDirectory, this._relativeFilename);
        enforce!ResourceException(path.length > 0, "Texture does not exist: " ~ this.filename);

        this._filename = path;

        File fileHandle;
        auto err = collectException!ErrnoException(File(path, "rb"), fileHandle);
        enforce!ResourceException(!err, err is null ? "" : err.msg);

        this.load(fileHandle.rawRead(new ubyte[fileHandle.size()]));
    }

    override void load(const(ubyte)[] buffer)
    {
        import std.exception : enforce;

        if (buffer.length >= 2 && buffer[0 .. 2] == ['B', 'M'])
        {
            this._image = decodeBmp(buffer, this.filename);
        }
        else
        {
            import std.path : extension;
            import std.uni : toLower;

            enforce!ResourceException(toLower(extension(this._relativeFilename)) == ".tga",
                    "Unsupported texture format: " ~ this.filename);
            this._image = decodeTga(buffer, this.filename);
        }

        this._usable = true;
    }
}

private Color rgba(uint r, uint g, uint b, uint a) pure nothrow @safe @nogc
{
    return Color((r & 0xFF) | ((g & 0xFF) << 8) | ((b & 0xFF) << 16) | ((a & 0xFF) << 24));
}

/// Pixels close to magenta are treated as transparent, like the client does
private bool isColorKey(uint r, uint g, uint b) pure nothrow @safe @nogc
{
    return r >= 0xF0 && g <= 0x0F && b >= 0xF0;
}

/// Throws: ResourceException
RawImage decodeBmp(const(ubyte)[] buffer, string name = "")
{
    import std.exception : enforce;
    import std.math : abs;

    enum error = "Bitmap is invalid or unsupported: ";

    enforce!ResourceException(buffer.length >= 54 && buffer[0 .. 2] == ['B', 'M'], error ~ name);

    const dataOffset = buffer.peekLE!uint(10);
    const headerSize = buffer.peekLE!uint(14);
    const width = buffer.peekLE!int(18);
    const rawHeight = buffer.peekLE!int(22);
    const bpp = buffer.peekLE!ushort(28);
    const compression = buffer.peekLE!uint(30);
    uint colorsUsed = buffer.peekLE!uint(46);

    enforce!ResourceException(width > 0 && rawHeight != 0 && width <= 4096 && abs(rawHeight) <= 4096, error ~ name);
    enforce!ResourceException(compression == 0 || (compression == 3 && bpp == 32), error ~ name);
    enforce!ResourceException(bpp == 4 || bpp == 8 || bpp == 24 || bpp == 32, error ~ name);

    const bool topDown = rawHeight < 0;
    const uint height = cast(uint) abs(rawHeight);
    const ulong stride = ((cast(ulong) width * bpp + 31) / 32) * 4;

    enforce!ResourceException(dataOffset + stride * height <= buffer.length, error ~ name);

    Color[] palette;
    if (bpp <= 8)
    {
        if (colorsUsed == 0 || colorsUsed > (1u << bpp))
        {
            colorsUsed = 1u << bpp;
        }
        const paletteOffset = 14 + headerSize;
        enforce!ResourceException(paletteOffset + colorsUsed * 4 <= buffer.length, error ~ name);
        palette = new Color[1u << bpp];
        foreach (i; 0 .. colorsUsed)
        {
            const p = paletteOffset + i * 4;
            const b = buffer[p], g = buffer[p + 1], r = buffer[p + 2];
            palette[i] = isColorKey(r, g, b) ? rgba(r, g, b, 0) : rgba(r, g, b, 0xFF);
        }
    }

    RawImage image;
    image.width = width;
    image.height = height;
    image.pixels = new Color[cast(ulong) width * height];

    bool hasAlpha = false;

    foreach (y; 0 .. height)
    {
        const row = dataOffset + stride * (topDown ? y : height - 1 - y);
        foreach (x; 0 .. width)
        {
            Color pixel;
            switch (bpp)
            {
            case 4:
                const value = buffer[row + x / 2];
                pixel = palette[(x % 2 == 0) ? (value >> 4) : (value & 0x0F)];
                break;
            case 8:
                pixel = palette[buffer[row + x]];
                break;
            case 24:
                const p = row + x * 3;
                const b = buffer[p], g = buffer[p + 1], r = buffer[p + 2];
                pixel = rgba(r, g, b, isColorKey(r, g, b) ? 0 : 0xFF);
                break;
            default: // 32
                const p = row + x * 4;
                const b = buffer[p], g = buffer[p + 1], r = buffer[p + 2], a = buffer[p + 3];
                hasAlpha = hasAlpha || a != 0;
                pixel = rgba(r, g, b, isColorKey(r, g, b) ? 0 : a);
                break;
            }
            image.pixels[cast(ulong) y * width + x] = pixel;
        }
    }

    if (bpp == 32 && !hasAlpha)
    {
        // The alpha channel is unused (X8R8G8B8). Treat as opaque.
        foreach (ref pixel; image.pixels)
        {
            if (!isColorKey(pixel.r, pixel.g, pixel.b))
            {
                pixel.a = 0xFF;
            }
        }
    }

    return image;
}

/// Throws: ResourceException
RawImage decodeTga(const(ubyte)[] buffer, string name = "")
{
    import std.exception : enforce;

    enum error = "Targa is invalid or unsupported: ";

    enforce!ResourceException(buffer.length >= 18, error ~ name);

    const idLength = buffer[0];
    const colorMapType = buffer[1];
    const imageType = buffer[2];
    const colorMapLength = buffer.peekLE!ushort(5);
    const colorMapDepth = buffer[7];
    const width = buffer.peekLE!ushort(12);
    const height = buffer.peekLE!ushort(14);
    const depth = buffer[16];
    const descriptor = buffer[17];

    const bool rle = imageType == 10 || imageType == 11;
    const bool gray = imageType == 3 || imageType == 11;

    enforce!ResourceException(imageType == 2 || imageType == 3 || imageType == 10 || imageType == 11, error ~ name);
    enforce!ResourceException(width > 0 && height > 0 && width <= 4096 && height <= 4096, error ~ name);
    enforce!ResourceException(gray ? depth == 8 : (depth == 24 || depth == 32), error ~ name);

    const bytesPerPixel = depth / 8;
    ulong offset = 18 + idLength;
    if (colorMapType == 1)
    {
        offset += colorMapLength * ((colorMapDepth + 7) / 8);
    }

    const pixelCount = cast(ulong) width * height;
    auto pixels = new Color[pixelCount];

    Color readPixel(ulong at)
    {
        enforce!ResourceException(at + bytesPerPixel <= buffer.length, error ~ name);
        if (gray)
        {
            const v = buffer[at];
            return rgba(v, v, v, 0xFF);
        }
        const b = buffer[at], g = buffer[at + 1], r = buffer[at + 2];
        const a = bytesPerPixel == 4 ? buffer[at + 3] : 0xFF;
        return rgba(r, g, b, a);
    }

    ulong index = 0;
    while (index < pixelCount)
    {
        if (!rle)
        {
            pixels[index++] = readPixel(offset);
            offset += bytesPerPixel;
            continue;
        }

        enforce!ResourceException(offset < buffer.length, error ~ name);
        const packet = buffer[offset++];
        const count = (packet & 0x7F) + 1;
        enforce!ResourceException(index + count <= pixelCount, error ~ name);

        if (packet & 0x80)
        {
            const pixel = readPixel(offset);
            offset += bytesPerPixel;
            pixels[index .. index + count] = pixel;
            index += count;
        }
        else
        {
            foreach (i; 0 .. count)
            {
                pixels[index++] = readPixel(offset);
                offset += bytesPerPixel;
            }
        }
    }

    const bool topToBottom = (descriptor & 0x20) != 0;
    const bool rightToLeft = (descriptor & 0x10) != 0;

    RawImage image;
    image.width = width;
    image.height = height;
    image.pixels = new Color[pixelCount];

    foreach (y; 0 .. height)
    {
        const srcY = topToBottom ? y : height - 1 - y;
        foreach (x; 0 .. width)
        {
            const srcX = rightToLeft ? width - 1 - x : x;
            image.pixels[cast(ulong) y * width + x] = pixels[cast(ulong) srcY * width + srcX];
        }
    }

    return image;
}

version (unittest)
{
    private ubyte[] bmpHeader(int width, int height, ushort bpp, uint paletteSize, uint dataSize)
    {
        import std.bitmanip : nativeToLittleEndian;

        const uint dataOffset = 54 + paletteSize * 4;
        ubyte[] data = ['B', 'M'];
        data ~= nativeToLittleEndian(cast(uint)(dataOffset + dataSize));
        data ~= nativeToLittleEndian(0u);
        data ~= nativeToLittleEndian(dataOffset);
        data ~= nativeToLittleEndian(40u);
        data ~= nativeToLittleEndian(width);
        data ~= nativeToLittleEndian(height);
        data ~= nativeToLittleEndian(cast(ushort) 1);
        data ~= nativeToLittleEndian(bpp);
        data ~= nativeToLittleEndian(0u); // compression
        data ~= nativeToLittleEndian(dataSize);
        data ~= nativeToLittleEndian(0);
        data ~= nativeToLittleEndian(0);
        data ~= nativeToLittleEndian(paletteSize);
        data ~= nativeToLittleEndian(0u);
        return data;
    }
}

unittest
{
    // 2x2 24-bit bottom-up: bottom row = [red, magenta], top row = [green, blue]
    auto data = bmpHeader(2, 2, 24, 0, 16);
    data ~= [0, 0, 255, 255, 0, 255, 0, 0]; // bottom row (+2 bytes padding)
    data ~= [0, 255, 0, 255, 0, 0, 0, 0]; // top row (+2 bytes padding)

    auto img = decodeBmp(data);
    assert(img.width == 2 && img.height == 2);
    assert(img.pixels[0] == rgba(0, 255, 0, 255)); // top left green
    assert(img.pixels[1] == rgba(0, 0, 255, 255)); // top right blue
    assert(img.pixels[2] == rgba(255, 0, 0, 255)); // bottom left red
    assert(img.pixels[3].a == 0); // magenta is transparent
}

unittest
{
    // 2x1 8-bit with palette [black, magenta, white]
    auto data = bmpHeader(2, 1, 8, 3, 4);
    data ~= [0, 0, 0, 0, 255, 0, 255, 0, 255, 255, 255, 0];
    data ~= [2, 1, 0, 0];

    auto img = decodeBmp(data);
    assert(img.pixels[0] == rgba(255, 255, 255, 255));
    assert(img.pixels[1].a == 0);
}

unittest
{
    import std.bitmanip : nativeToLittleEndian;

    ubyte[] header(ubyte type, ubyte depth, ubyte descriptor)
    {
        ubyte[] h = [0, 0, type, 0, 0, 0, 0, 0, 0, 0, 0, 0];
        h ~= nativeToLittleEndian(cast(ushort) 2);
        h ~= nativeToLittleEndian(cast(ushort) 2);
        h ~= [depth, descriptor];
        return h;
    }

    // Uncompressed 32-bit, bottom-up
    auto raw = header(2, 32, 0);
    raw ~= [1, 2, 3, 4, 5, 6, 7, 8]; // bottom row
    raw ~= [9, 10, 11, 12, 13, 14, 15, 16]; // top row
    auto img = decodeTga(raw);
    assert(img.pixels[0] == rgba(11, 10, 9, 12));
    assert(img.pixels[2] == rgba(3, 2, 1, 4));

    // RLE 24-bit, top-down: one run of 3 and one raw pixel
    auto rle = header(10, 24, 0x20);
    rle ~= [0x82, 10, 20, 30];
    rle ~= [0x00, 40, 50, 60];
    auto img2 = decodeTga(rle);
    assert(img2.pixels[0] == rgba(30, 20, 10, 255));
    assert(img2.pixels[2] == rgba(30, 20, 10, 255));
    assert(img2.pixels[3] == rgba(60, 50, 40, 255));
}
