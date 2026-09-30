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
    import std.file : exists, isDir, dirEntries, SpanMode, FileException;
    import std.path : buildPath, baseName, pathSplitter;
    import std.uni : toLower;

    const exactPath = buildPath(baseDirectory, relativePath);

    if (exists(exactPath))
    {
        return exactPath;
    }

    string current = baseDirectory;

    foreach (component; pathSplitter(relativePath))
    {
        const candidate = buildPath(current, component);
        if (exists(candidate))
        {
            current = candidate;
            continue;
        }

        if (!exists(current) || !isDir(current))
        {
            return "";
        }

        const lowerComponent = toLower(component);
        string found;

        try
        {
            foreach (entry; dirEntries(current, SpanMode.shallow, false))
            {
                if (toLower(baseName(entry.name)) == lowerComponent)
                {
                    found = entry.name;
                    break;
                }
            }
        }
        catch (FileException err)
        {
            return "";
        }

        if (found.length == 0)
        {
            return "";
        }

        current = found;
    }

    return current;
}

unittest
{
    import std.file : mkdirRecurse, write, rmdirRecurse, tempDir, exists;
    import std.path : buildPath;
    import std.conv : to;
    import std.process : thisProcessID;

    const base = buildPath(tempDir(), "zrenderer_casepath_" ~ thisProcessID.to!string);
    mkdirRecurse(buildPath(base, "Effect", "Spot_Light"));
    scope (exit) rmdirRecurse(base);

    write(buildPath(base, "Effect", "Spot_Light", "Spotlight.str"), "x");

    assert(findPathCaseInsensitive(base, "Effect/Spot_Light/Spotlight.str") ==
            buildPath(base, "Effect", "Spot_Light", "Spotlight.str"));
    assert(findPathCaseInsensitive(base, "effect/spot_light/spotlight.str") ==
            buildPath(base, "Effect", "Spot_Light", "Spotlight.str"));
    assert(findPathCaseInsensitive(base, "effect/missing.str") == "");
}
