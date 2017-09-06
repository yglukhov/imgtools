import tables, sets, times, math, algorithm, logging
import nimPNG
import rect_packer

import imgtools

const multithreaded = compileOption("threads")
const useNewThreadpool = true

when multithreaded:
    when useNewThreadpool:
        import threadpool_simple as ts # TODO: This should eventually end up in nim stdlib

    template `^^`[T](e: FlowVar[T]): untyped = ^e
else:
    type FlowVar[T] = T
    template spawn(e: typed): untyped = e
    template `^^`(e: FlowVar): untyped = e
    template sync() = discard
    template spawnX(e: typed): untyped = e

type
    SpriteSheetPacker* = ref object
        outputPrefix: string
        spriteSheets*: seq[SpriteSheet]

    ImageOccurence*[TInfo] = object
        path*: string
        allowAlphaCrop*: bool
        disablePotAdjustment*: bool
        category*: string
        downsampleRatio*: float
        extrusion*: int

        spriteSheet*: SpriteSheet
        dstBounds*: Rect
        srcInfo*: SourceImageInfo
        info*: TInfo

    Size* = tuple[width, height: int]
    
    SourceImage = object
        path: string
        allowAlphaCrop: bool
        disablePotAdjustment: bool
        downsampleRatio: float
        extrusion: int
        spriteSheet: SpriteSheet
        dstBounds: Rect
        srcInfo: SourceImageInfo

    SourceImageInfo = tuple[rect: Rect, size: Size]

    SpriteSheet* = ref object
        packer: RectPacker
        size*: Size
        category*: string
        path*: string # Index of sprite sheet in tool.images array

proc newSpriteSheetPacker*(outputPrefix: string): SpriteSheetPacker =
    result.new()
    result.outputPrefix = outputPrefix

proc newSpriteSheet(minSize: Size): SpriteSheet =
    result.new()
    let px = max(nextPowerOfTwo(minSize.width), 1024)
    let py = max(nextPowerOfTwo(minSize.height), 1024)
    result.packer = newPacker(px.int32, py.int32)
    result.packer.maxX = px.int32
    result.packer.maxY = py.int32

proc readImageInfo(path: string, allowAlphaCrop: bool): SourceImageInfo {.gcsafe.} =
    let png = loadPNG32(path)
    if png.isNil:
        raise newException(Exception, "Could not load " & path)

    result.size = (png.width, png.height)

    if allowAlphaCrop:
        result.rect = imageBounds(png.data, png.width, png.height)
    else:
        result.rect.width = png.width
        result.rect.height = png.height

proc readSourceInfo(sourceImages: var openarray[SourceImage]) =
    var imageBoundsResults = newSeq[FlowVar[SourceImageInfo]](sourceImages.len)
    for i in 0 ..< sourceImages.len:
        imageBoundsResults[i] = spawn readImageInfo(sourceImages[i].path, sourceImages[i].allowAlphaCrop)

    for i in 0 ..< sourceImages.len:
        sourceImages[i].srcInfo = ^^imageBoundsResults[i]

proc betterDimension(dimension, extrusion: int, downsampleRatio: float, disablePotAdjustment: bool): int =
    let r = int(dimension.float / downsampleRatio)
    if disablePotAdjustment:
        return r
    var changed = true
    result = case r + extrusion * 2
        of 257 .. 400: 256
        of 513 .. 700: 512
        of 1025 .. 1300: 1024
        else:
            changed = false
            r
    if result > 2048: result = 2048
    if changed:
        result -= extrusion * 2

proc calculateTargetSize(si: var SourceImage) =
    si.dstBounds.width = betterDimension(si.srcInfo.rect.width, si.extrusion, si.downsampleRatio, si.disablePotAdjustment)
    si.dstBounds.height = betterDimension(si.srcInfo.rect.height, si.extrusion, si.downsampleRatio, si.disablePotAdjustment)

proc tryPackImage(ss: SpriteSheet, im: var SourceImage): bool =
    let pos = ss.packer.packAndGrow(im.dstBounds.width.int32 + im.extrusion.int32 * 2, im.dstBounds.height.int32 + im.extrusion.int32 * 2)
    result = pos.hasSpace
    if result:
        im.dstBounds.x = pos.x + im.extrusion
        im.dstBounds.y = pos.y + im.extrusion
        im.spriteSheet = ss

proc packImagesToSpritesheets(images: var openarray[SourceImage], spritesheets: var seq[SpriteSheet]) =
    for i, im in images.mpairs:
        var done = false
        for ss in spritesheets:
            done = ss.tryPackImage(im)
            if done: break
        if not done:
            let newSS = newSpriteSheet((im.dstBounds.width + im.extrusion * 2, im.dstBounds.height + im.extrusion * 2))
            done = newSS.tryPackImage(im)
            if done:
                spritesheets.add(newSS)
            else:
                raise newException(Exception, "Could not pack image: " & im.path)

proc assignImagesToSpritesheets(imgs: var seq[SourceImage]): seq[SpriteSheet] =
    var try1 = newSeq[SpriteSheet]()
    var try2 = newSeq[SpriteSheet]()
    shallow(try1)
    shallow(try2)

    # First approach
    imgs.sort do(x, y: SourceImage) -> int:
        max(y.dstBounds.width, y.dstBounds.height) - max(x.dstBounds.width, x.dstBounds.height)
    packImagesToSpritesheets(imgs, try1)

    # Second approach
    imgs.sort do(x, y: SourceImage) -> int:
        y.dstBounds.width * y.dstBounds.height - x.dstBounds.width * x.dstBounds.height
    packImagesToSpritesheets(imgs, try2)

    # Choose better approach
    if try1.len < try2.len:
        # Redo try1 again
        imgs.sort do(x, y: SourceImage) -> int:
            max(y.dstBounds.width, y.dstBounds.height) - max(x.dstBounds.width, x.dstBounds.height)
        try1.setLen(0)
        packImagesToSpritesheets(imgs, try1)
        result = try1
    else:
        result = try2

proc composeAndWrite(ss: SpriteSheet, images: seq[SourceImage]) {.gcsafe.} = # seq is better than openarray for spawn
    var data = newString(ss.size.width * ss.size.height * 4)
    for im in images:
        var png = loadPNG32(im.path)

        if png.data.len == png.width * png.height * 4:
            zeroColorIfZeroAlpha(png.data)
            colorBleed(png.data, png.width, png.height)

        if im.srcInfo.size.width == im.dstBounds.width and im.srcInfo.size.height == im.dstBounds.height:
            blitImage(
                data, ss.size.width, ss.size.height, # Target image
                im.dstBounds.x, im.dstBounds.y, # Position in target image
                png.data, png.width, png.height,
                im.srcInfo.rect.x, im.srcInfo.rect.y, im.srcInfo.rect.width, im.srcInfo.rect.height)
        else:
            resizeImage(png.data, png.width, png.height,
                data, ss.size.width, ss.size.height,
                im.srcInfo.rect.x, im.srcInfo.rect.y, im.srcInfo.rect.width, im.srcInfo.rect.height,
                im.dstBounds.x, im.dstBounds.y, im.dstBounds.width, im.dstBounds.height)

        png = nil

        extrudeBorderPixels(
            data,
            ss.size.width,
            ss.size.height,
            im.dstBounds.x - im.extrusion,
            im.dstBounds.y - im.extrusion,
            im.dstBounds.width + im.extrusion * 2,
            im.dstBounds.height + im.extrusion * 2,
            im.extrusion
        )

    discard savePNG32(ss.path, data, ss.size.width, ss.size.height)
    data = nil

proc packCategory*(packer: SpriteSheetPacker, occurences: var openarray[ImageOccurence], category: string) =
    var images = initTable[string, seq[int]]()
    for i, o in occurences:
        if o.category == category:
            if o.path in images:
                images[o.path].add(i)
            else:
                images[o.path] = @[i]

    var sourceImages = newSeq[SourceImage]()
    for k, v in images:
        var si: SourceImage
        si.path = k
        si.allowAlphaCrop = true

        for idx in v:
            if not occurences[idx].allowAlphaCrop:
                si.allowAlphaCrop = false

            let dr = occurences[idx].downsampleRatio
            if dr != 0 and dr > si.downsampleRatio:
                si.downsampleRatio = dr

            if occurences[idx].extrusion > si.extrusion:
                si.extrusion = occurences[idx].extrusion

            if occurences[idx].disablePotAdjustment:
                si.disablePotAdjustment = true

        if si.downsampleRatio < 1: si.downsampleRatio = 1
        sourceImages.add(si)

    info "Packing category ", (if category.isNil: "nil" else: category), " with ", occurences.len, " images, ", sourceImages.len, " unique"

    var s = epochTime()
    readSourceInfo(sourceImages)
    var e = epochTime()
    info "Images read (seconds): ", e - s

    for i in 0 ..< sourceImages.len:
        calculateTargetSize(sourceImages[i])

    var spriteSheets = assignImagesToSpritesheets(sourceImages)
    let spriteSheetIdxOffset = packer.spriteSheets.len
    for i, ss in spriteSheets:
        ss.size.width = ss.packer.width
        ss.size.height = ss.packer.height
        ss.packer = nil
        ss.path = packer.outputPrefix & $(spriteSheetIdxOffset + i) & ".png"

    var ssImages = newSeq[SourceImage]()
    s = epochTime()

    info "Total sprite sheets: ", spriteSheets.len

    for i, ss in spriteSheets:
        ssImages.setLen(0)
        info "Sprite sheet ", (i + 1), ": ", ss.path
        for i in 0 ..< sourceImages.len:
            if sourceImages[i].spriteSheet == ss:
                ssImages.add(sourceImages[i])
                ssImages[^1].spriteSheet = nil
        spawnX composeAndWrite(ss, ssImages)
    sync()

    e = epochTime()
    info "Spritesheets written (seconds): ", e - s

    var category = category
    for ss in spriteSheets:
        shallowCopy(ss.category, category)

    packer.spriteSheets &= spriteSheets

    for im in sourceImages:
        for idx in images[im.path]:
            occurences[idx].spriteSheet = im.spriteSheet
            occurences[idx].dstBounds = im.dstBounds
            occurences[idx].srcInfo = im.srcInfo

proc pack*(packer: SpriteSheetPacker, occurences: var openarray[ImageOccurence]) =
    var categories = initSet[string]()
    for o in occurences:
        categories.incl(o.category)

    packer.spriteSheets = @[]
    for c in categories:
        packer.packCategory(occurences, c)
