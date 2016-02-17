import osproc, os, strutils

var texTool: string

proc nimblePath(package: string): string =
    var (nimbleNimxDir, err) = execCmdEx("nimble path " & package)
    if err == 0:
        let lines = nimbleNimxDir.splitLines()
        if lines.len > 1:
            result = lines[^2]

proc texToolPath(): string =
    if texTool.isNil:
        let imgtoolsPath = nimblePath("imgtools")
        doAssert(not imgtoolsPath.isNil, "imgtools is not installed in nimble packages")
        const osname = when defined(macosx):
                "OSX_x86"
            elif defined(windows):
                when hostCPU == "i386":
                    "Windows_x86_32"
                elif hostCPU == "amd64":
                    "Windows_x86_64"
                else:
                    nil
            elif defined(linux):
                when hostCPU == "i386":
                    "Linux_x86_32"
                elif hostCPU == "amd64":
                    "Linux_x86_64"
                else:
                    nil
            else:
                nil

        when osname.isNil:
            {.error: "Unsupported platform".}

        texTool = imgtoolsPath / "pvrtextool" / "CLI" / osname / "PVRTexToolCLI"
    result = texTool

proc convertToETC2*(fromPath, toPath: string) =
    var args = [texToolPath(), "-i", fromPath, "-o", toPath, "-f", "ETC2_RGBA", "-q", "etcfast"]
    let errC = execCmd(args.join(" "))
    if errC != 0:
        raise newException(Exception, "PVRImgtool exited with code " & $errC)
