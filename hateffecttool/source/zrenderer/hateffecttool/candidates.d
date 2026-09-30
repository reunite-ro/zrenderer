module zrenderer.hateffecttool.candidates;

private enum MaxCandidates = 3;

struct Candidate
{
    string type;
    string file;
    size_t distance;
}

/// Lowercase alphanumeric characters only
private string normalize(string name)
{
    import std.array : appender;
    import std.ascii : isAlphaNum, toLower;

    auto result = appender!string;
    foreach (char c; name)
    {
        if (isAlphaNum(c))
        {
            result.put(toLower(c));
        }
    }
    return result.data;
}

private string normalizedHatEffectName(string name)
{
    import std.algorithm.searching : startsWith;
    import std.uni : toLower;

    auto lower = toLower(name);
    foreach (prefix; ["hat_ef_", "ef_"])
    {
        if (lower.startsWith(prefix))
        {
            lower = lower[prefix.length .. $];
            break;
        }
    }
    if (lower.startsWith("c_"))
    {
        lower = lower[2 .. $];
    }

    return normalize(lower);
}

Candidate[] findCandidates(string hatEffectName, const scope string[] strFiles, const scope string[] sprFiles)
{
    import std.algorithm.comparison : levenshteinDistance, min;
    import std.algorithm.searching : canFind;
    import std.algorithm.sorting : sort;
    import std.path : baseName, dirName, stripExtension;

    const target = normalizedHatEffectName(hatEffectName);
    if (target.length < 3)
    {
        return [];
    }

    Candidate[] candidates;

    void consider(string type, string file, string displayFile)
    {
        // Compare with the file name as well as with its folder (e.g. "efst_xyz/xyz.str")
        const stem = normalize(stripExtension(baseName(file)));
        const folder = normalize(dirName(file) == "." ? "" : baseName(dirName(file)));

        size_t best = size_t.max;
        foreach (name; [stem, folder, normalize(folder.length > 4 && folder[0 .. 4] == "efst" ? folder[4 .. $] : folder)])
        {
            if (name.length == 0)
            {
                continue;
            }
            if (name == target)
            {
                best = 0;
                break;
            }
            if (name.length >= 4 && (name.canFind(target) || target.canFind(name)))
            {
                best = min(best, 1);
                continue;
            }
            best = min(best, levenshteinDistance(name, target));
        }

        // Only reasonably similar names
        if (best <= target.length / 3)
        {
            candidates ~= Candidate(type, displayFile, best);
        }
    }

    foreach (file; strFiles)
    {
        consider("STR", file, file);
    }
    foreach (file; sprFiles)
    {
        consider("SPR", file, stripExtension(file));
    }

    candidates.sort!((a, b) => a.distance < b.distance || (a.distance == b.distance && a.file < b.file));

    return candidates[0 .. min(MaxCandidates, candidates.length)];
}

unittest
{
    assert(normalizedHatEffectName("HAT_EF_C_Spot_Light") == "spotlight");
    assert(normalizedHatEffectName("HAT_EF_Digital_Space") == "digitalspace");

    auto candidates = findCandidates("HAT_EF_C_2025RosFesta",
            ["2025rosfesta/rose.str", "efst_blossom_fluttering/sakura.str", "sleep.str"], ["digital_space"]);
    assert(candidates.length == 1);
    assert(candidates[0].file == "2025rosfesta/rose.str");

    auto spr = findCandidates("HAT_EF_Digital_Space", ["sleep.str"], ["digital_space/digital_space.spr"]);
    assert(spr.length == 1 && spr[0].type == "SPR" && spr[0].file == "digital_space/digital_space");
}
