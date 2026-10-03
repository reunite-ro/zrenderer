module resource.casepath;

/**
  Returns the path as it exists on disk. If the exact path does not exist
  every path component below baseDirectory is looked up case-insensitively.
  This is needed because the client data (e.g. hateffectinfo) references files
  with mixed casing that do not necessarily match the extracted files.
  Returns: The existing path or an empty string if nothing was found.
 */
string findPathCaseInsensitive(string baseDirectory, string relativePath)
{
    import std.array : array;
    import std.file : exists;
    import std.path : buildPath, pathSplitter;

    const exactPath = buildPath(baseDirectory, relativePath);

    if (exists(exactPath))
    {
        return exactPath;
    }

    return findComponents(baseDirectory, pathSplitter(relativePath).array);
}

/**
  Resolves the path components below directory. Data extracted from several
  GRFs on a case sensitive file system can contain the same folder more than
  once with different casing (e.g. efst_C_Dark_Lord_Cloak and
  efst_c_dark_lord_cloak, each with some of the files), so every matching
  entry is tried, the exact casing first.
 */
private string findComponents(string directory, const scope string[] components)
{
    import std.file : exists, isDir, dirEntries, SpanMode, FileException;
    import std.path : buildPath, baseName;
    import std.uni : toLower;

    if (components.length == 0)
    {
        return directory;
    }

    string[] matches;

    const exact = buildPath(directory, components[0]);
    if (exists(exact))
    {
        matches ~= exact;
    }

    const lowerComponent = toLower(components[0]);

    try
    {
        foreach (entry; dirEntries(directory, SpanMode.shallow, false))
        {
            const name = baseName(entry.name);
            if (name != components[0] && toLower(name) == lowerComponent)
            {
                matches ~= entry.name;
            }
        }
    }
    catch (FileException err)
    {
        // Not a readable directory, only the exact match is left to try
    }

    foreach (match; matches)
    {
        if (components.length == 1)
        {
            return match;
        }

        if (isDir(match))
        {
            const found = findComponents(match, components[1 .. $]);
            if (found.length > 0)
            {
                return found;
            }
        }
    }

    return "";
}

unittest
{
    import std.file : mkdirRecurse, write, rmdirRecurse, tempDir, exists;
    import std.path : buildPath, buildNormalizedPath, filenameCmp;
    import std.conv : to;
    import std.process : thisProcessID;

    const base = buildPath(tempDir(), "zrenderer_casepath_" ~ thisProcessID.to!string);
    mkdirRecurse(buildPath(base, "Effect", "Spot_Light"));
    scope (exit) rmdirRecurse(base);

    const expected = buildPath(base, "Effect", "Spot_Light", "Spotlight.str");
    write(expected, "x");

    // Separators may be mixed and Windows file systems are case insensitive
    bool samePath(string path)
    {
        return filenameCmp(buildNormalizedPath(path), expected) == 0;
    }

    assert(samePath(findPathCaseInsensitive(base, "Effect/Spot_Light/Spotlight.str")));
    assert(samePath(findPathCaseInsensitive(base, "effect/spot_light/spotlight.str")));
    assert(findPathCaseInsensitive(base, "effect/missing.str") == "");

    // The same folder in two casings (one folder on case insensitive file systems), the file
    // is only in the one that doesn't match the requested casing exactly
    mkdirRecurse(buildPath(base, "Split", "Dark_Lord"));
    mkdirRecurse(buildPath(base, "Split", "dark_lord"));
    write(buildPath(base, "Split", "Dark_Lord", "cloak.ezv"), "x");
    write(buildPath(base, "Split", "dark_lord", "cloak.str"), "x");

    assert(findPathCaseInsensitive(base, "Split/Dark_Lord/cloak.str").length > 0);
    assert(findPathCaseInsensitive(base, "split/DARK_LORD/cloak.ezv").length > 0);
    assert(findPathCaseInsensitive(base, "Split/Dark_Lord/missing.str") == "");
}
