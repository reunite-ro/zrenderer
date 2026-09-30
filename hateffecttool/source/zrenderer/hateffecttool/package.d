module zrenderer.hateffecttool;

import config : Config;
import hateffect : EffectTableEntry, HatEffectTableFile, effectTableEntries, hatEffectInfo;
import logging : LogLevel, BasicLogger;
import luad.state : LuaState;
import resource : ResourceManager, ResourceException, buildFilepath;
import std.getopt : GetoptResult, GetOptException;
import std.stdio : writeln, writefln, stderr;
import zrenderer.hateffecttool.candidates : findCandidates;

enum usage = "Lists all hat effects of the client data and whether zrenderer can draw them.\n" ~
    "For hat effects that use a client effect without an entry in " ~ HatEffectTableFile ~ "\n" ~
    "candidate files are suggested based on the hat effect name.";

private enum EffectSpriteFolder = "이팩트";

int main(string[] args)
{
    import zconfig : loadConfig, ConfigLoaderConfig;
    import std.conv : ConvException;

    ConfigLoaderConfig clc = { configFilename: "zrenderer.conf" };
    GetoptResult helpInformation;
    Config config;

    try
    {
        config = loadConfig!(Config, usage)(args, helpInformation, clc);
    }
    catch (GetOptException e)
    {
        stderr.writefln("Error parsing options: %s", e.msg);
        return 1;
    }
    catch (ConvException e)
    {
        stderr.writefln("Error parsing options: %s", e.msg);
        return 1;
    }

    if (helpInformation.helpWanted)
    {
        return 0;
    }

    import std.algorithm.comparison : max;

    auto logger = BasicLogger.get(max(config.loglevel, LogLevel.warning));

    void consoleLogger(LogLevel logLevel, string msg)
    {
        logger.log(logLevel, msg);
    }

    auto L = new LuaState;
    L.openLibs();

    auto resManager = new ResourceManager(config.resourcepath);

    try
    {
        import luamanager : loadRequiredLuaFiles;

        loadRequiredLuaFiles(L, resManager, &consoleLogger);
    }
    catch (ResourceException err)
    {
        stderr.writeln(err.msg);
        return 1;
    }

    const effectDirectory = buildFilepath(config.resourcepath, "texture/effect", "");
    const spriteDirectory = buildFilepath(config.resourcepath, "sprite/" ~ EffectSpriteFolder, "");

    const strFiles = listFiles(effectDirectory, "*.{str,STR,Str}", true);
    const sprFiles = listFiles(spriteDirectory, "*.{spr,SPR,Spr}", false);

    uint[string] statusCount;
    string[] suggestions;

    foreach (entry; hatEffectListing(L))
    {
        const info = hatEffectInfo(entry.id, L);
        string kind;
        string status = "OK";
        string detail;

        if (info.resourceFileName.length > 0)
        {
            kind = info.effectId >= 0 ? "STR+EFFECT" : "STR";
            if (!effectFileExists(effectDirectory, info.resourceFileName))
            {
                status = "MISSING FILE";
                detail = info.resourceFileName;
            }
            else
            {
                detail = info.resourceFileName;
            }
        }
        else if (info.effectId >= 0)
        {
            kind = "EFFECT";
        }
        else
        {
            kind = "EMPTY";
            status = "NOTHING TO DRAW";
        }

        if (info.effectId >= 0)
        {
            auto tableEntries = effectTableEntries(info.effectId, L);
            if (tableEntries.length == 0)
            {
                status = "NO TABLE ENTRY";
                detail ~= (detail.length > 0 ? ", " : "") ~ "effect " ~ toStr(info.effectId);

                auto candidates = findCandidates(entry.name, strFiles, sprFiles);
                if (candidates.length > 0)
                {
                    import std.format : format;

                    suggestions ~= format("\t[%d] = { { type = \"%s\", file = \"%s\" } }, -- %s (hat effect %d)",
                            info.effectId, candidates[0].type, candidates[0].file, entry.name, entry.id);
                    foreach (candidate; candidates[1 .. $])
                    {
                        suggestions ~= format("\t-- alternative: { type = \"%s\", file = \"%s\" }",
                                candidate.type, candidate.file);
                    }
                }
            }
            else
            {
                foreach (tableEntry; tableEntries)
                {
                    if (!tableEntryExists(tableEntry, effectDirectory, spriteDirectory))
                    {
                        status = "MISSING FILE";
                        detail ~= (detail.length > 0 ? ", " : "") ~ tableEntry.file;
                    }
                }
                if (status == "OK")
                {
                    detail ~= (detail.length > 0 ? ", " : "") ~ "effect " ~ toStr(info.effectId);
                }
            }
        }

        statusCount[status]++;
        writefln("%5d  %-40s %-11s %-16s %s", entry.id, entry.name, kind, status, detail);
    }

    writeln();
    writeln("Summary:");
    foreach (status, count; statusCount)
    {
        writefln("  %-16s %d", status, count);
    }

    if (suggestions.length > 0)
    {
        writeln();
        writeln("Suggested entries for " ~ HatEffectTableFile ~ " (verify before use):");
        foreach (line; suggestions)
        {
            writeln(line);
        }
    }

    return 0;
}

private string toStr(T)(T value)
{
    import std.conv : to;

    return value.to!string;
}

struct ListingEntry
{
    uint id;
    string name;
}

private ListingEntry[] hatEffectListing(ref LuaState L)
{
    import luad.lfunction : LuaFunction;
    import std.algorithm.iteration : splitter;
    import std.conv : to, ConvException;
    import std.string : lineSplitter;

    ListingEntry[] entries;

    const listing = L.get!LuaFunction("__zr_HatEffectListing").call!string();

    foreach (line; listing.lineSplitter)
    {
        auto parts = line.splitter('\t');
        if (parts.empty)
        {
            continue;
        }

        ListingEntry entry;
        try
        {
            entry.id = parts.front.to!uint;
        }
        catch (ConvException err)
        {
            continue;
        }
        parts.popFront();
        entry.name = parts.empty ? "" : parts.front;
        entries ~= entry;
    }

    return entries;
}

private bool effectFileExists(string effectDirectory, string file)
{
    import resource.casepath : findPathCaseInsensitive;

    return findPathCaseInsensitive(effectDirectory, file).length > 0;
}

private bool tableEntryExists(const scope EffectTableEntry entry, string effectDirectory, string spriteDirectory)
{
    import resource.casepath : findPathCaseInsensitive;

    switch (entry.type)
    {
    case "STR":
        return findPathCaseInsensitive(effectDirectory, entry.file).length > 0;
    case "SPR":
        return findPathCaseInsensitive(spriteDirectory, entry.file ~ ".spr").length > 0 &&
            findPathCaseInsensitive(spriteDirectory, entry.file ~ ".act").length > 0;
    default:
        return true;
    }
}

/// Lists files relative to the directory using '/' as separator
private string[] listFiles(string directory, string pattern, bool recursive)
{
    import std.array : replace;
    import std.file : dirEntries, exists, isDir, SpanMode, FileException;
    import std.path : relativePath, dirSeparator;

    string[] files;

    if (!exists(directory) || !isDir(directory))
    {
        return files;
    }

    try
    {
        foreach (entry; dirEntries(directory, pattern, recursive ? SpanMode.depth : SpanMode.shallow, false))
        {
            if (entry.isFile)
            {
                files ~= relativePath(entry.name, directory).replace(dirSeparator, "/");
            }
        }
    }
    catch (FileException err)
    {
        stderr.writeln(err.msg);
    }

    return files;
}
