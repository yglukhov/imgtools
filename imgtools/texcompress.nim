import osproc, os, strutils

proc nimblePath(package: string): string =
    var nimblecmd = "nimble"
    when defined(windows):
        nimblecmd &= ".cmd"
    var (nimbleNimxDir, err) = execCmdEx( nimblecmd & " path " & package)
    if err == 0:
        let lines = nimbleNimxDir.splitLines()
        if lines.len > 1:
            result = lines[^2]

var texTool {.threadVar.}: string

proc texToolPath(): string =
    if texTool.len == 0:
        let imgtoolsPath = nimblePath("imgtools")
        doAssert(imgtoolsPath.len != 0, "imgtools is not installed in nimble packages")
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

        when osname.len == 0:
            {.error: "Unsupported platform".}

        texTool = imgtoolsPath / "pvrtextool" / "CLI" / osname / "PVRTexToolCLI"
    result = texTool

proc convertToETC2*(fromPath, toPath: string, highQuality: bool = false) =
    var args = @[texToolPath(), "-i", fromPath, "-o", toPath, "-f", "ETC2_RGBA"]
    if highQuality:
        args.add(["-q", "etcslowperceptual"])
    else:
        args.add(["-q", "etcfastperceptual"])

    let errC = execCmd(args.join(" "))
    if errC != 0:
        raise newException(Exception, "PVRImgtool exited with code " & $errC)
