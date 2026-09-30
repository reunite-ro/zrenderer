module zrenderer.cli;

import config : Config;
import zconfig : loadConfig, ConfigLoaderConfig;
import logging : LogLevel, BasicLogger;
import std.getopt : GetoptResult, GetOptException;
import std.conv : ConvException;

enum usage = "A tool to render sprites from Ragnarok Online";

int main(string[] args)
{

    ConfigLoaderConfig clc = { configFilename: "zrenderer.conf" };
    GetoptResult helpInformation;

    Config config;

    try
    {
        config = loadConfig!(Config, usage)(args, helpInformation, clc);

        import std.exception : enforce;
        import validation : isJobArgValid, isCanvasArgValid, isHatEffectArgValid;

        enforce!GetOptException(isJobArgValid(config.job), "job ids are not valid.");
        enforce!GetOptException(isCanvasArgValid(config.canvas), "canvas is not valid.");
        enforce!GetOptException(isHatEffectArgValid(config.hateffect), "too many hateffect values.");
    }
    catch (GetOptException e)
    {
        import std.stdio : stderr;

        stderr.writefln("Error parsing options: %s", e.msg);
        return 1;
    }
    catch (ConvException e)
    {
        import std.stdio : stderr;

        stderr.writefln("Error parsing options: %s", e.msg);
        return 1;
    }

    if (helpInformation.helpWanted)
    {
        return 0;
    }

    import app : run, createOutputDirectory;

    createOutputDirectory(config.outdir);

    auto logger = BasicLogger.get(config.loglevel);

    void consoleLogger(LogLevel logLevel, string msg)
    {
        logger.log(logLevel,msg);
    }

    run(cast(immutable) config, &consoleLogger);

    return 0;
}
