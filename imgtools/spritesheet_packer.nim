import tables, sets, times, math, algorithm, logging, os, streams
import nimPNG
import rect_packer
import nimwebp / encoder
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
        maxTextureSize*: int
        useWebp*: bool
        webpQuality*: float
        webpLossless*: bool

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
        mPath: string
        packedIndexes: seq[int] # indexes of packed images
        useWebp: bool
        webpQuality: float
        webpLossless: bool

proc newSpriteSheetPacker*(outputPrefix: string): SpriteSheetPacker =
    result.new()
    result.outputPrefix = outputPrefix
    result.maxTextureSize = 1024

proc newSpriteSheet(maxSize: Size): SpriteSheet =
    result.new()
    let px = nextPowerOfTwo(maxSize.width)
    let py = nextPowerOfTwo(maxSize.height)
    result.packer = newPacker(px.int32, py.int32)
    result.packer.maxX = px.int32
    result.packer.maxY = py.int32

proc `path=`*(ss: SpriteSheet, v:string) = ss.mPath = v
proc path*(ss: SpriteSheet): string = ss.mPath & (if ss.useWebp: ".webp" else: ".png")

proc loadPNG32AUX(fileName: string, settings = PNGDecoder(nil)): PNGResult {.gcsafe.} =
    {.gcsafe.}:
        result = loadPNG32(fileName, settings)

proc savePNG32AUX(fileName, input: string, w, h: int): bool {.gcsafe.} =
    {.gcsafe.}:
        result = savePNG32(fileName, input, w, h)

proc readImageInfo(path: string, allowAlphaCrop: bool): SourceImageInfo {.gcsafe.} =
    let png = loadPNG32AUX(path)
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

    sync()

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
    if result > 2048:
        result = 2048
        changed = true
    if changed:
        result -= extrusion * 2

proc calculateTargetSize(si: var SourceImage) =
    let r = si.srcInfo.rect.height / si.srcInfo.rect.width
    si.dstBounds.width = betterDimension(si.srcInfo.rect.width, si.extrusion, si.downsampleRatio, si.disablePotAdjustment)
    si.dstBounds.height = int32(si.dstBounds.width.float * r)

proc tryPackImage(ss: SpriteSheet, im: var SourceImage, withGrow: bool = true): bool =
    var pos: tuple[x, y: int32]
    let w = im.dstBounds.width.int32 + im.extrusion.int32 * 2
    let h = im.dstBounds.height.int32 + im.extrusion.int32 * 2
    if withGrow:
        pos = ss.packer.packAndGrow(w, h)
    else:
        pos = ss.packer.pack(w, h)
    result = pos.hasSpace
    if result:
        im.dstBounds.x = pos.x + im.extrusion
        im.dstBounds.y = pos.y + im.extrusion
        im.spriteSheet = ss

proc packImagesToSpritesheets(p: SpriteSheetPacker, images: var openarray[SourceImage], spritesheets: var seq[SpriteSheet]) =
    for i, im in images.mpairs:
        var done = false
        for ss in spritesheets:
            done = ss.tryPackImage(im)
            if done:
                ss.packedIndexes.add(i)
                break
        if not done:
            let w = max(p.maxTextureSize, im.dstBounds.width + im.extrusion * 2)
            let h = max(p.maxTextureSize, im.dstBounds.height + im.extrusion * 2)
            let newSS = newSpriteSheet((w, h))
            done = newSS.tryPackImage(im)
            if done:
                newSS.packedIndexes.add(i)
                spritesheets.add(newSS)
            else:
                raise newException(Exception, "Could not pack image: " & im.path)

proc optimizeLastSheet(ls: var SpriteSheet, images: var openarray[SourceImage]) =
    var w = ls.packer.width
    var h = ls.packer.height
    var opt = true
    var dh = true # true is height
    while opt:
        if dh:
            h = h div 2
        else:
            w = w div 2
        let newSS = newSpriteSheet((w.int, h.int))
        for imgi in ls.packedIndexes:
            if not newSS.tryPackImage(images[imgi], withGrow = false):
                opt = false
                if dh: # restore previous fittable size
                    h = h * 2
                else:
                    w = w * 2
                break
        dh = not dh

    var newSS = newSpriteSheet((w.int, h.int))
    for imgi in ls.packedIndexes:
        discard newSS.tryPackImage(images[imgi])
    ls = newSS

proc assignImagesToSpritesheets(p: SpriteSheetPacker, imgs: var seq[SourceImage]): seq[SpriteSheet] =
    var try1 = newSeq[SpriteSheet]()
    var try2 = newSeq[SpriteSheet]()
    shallow(try1)
    shallow(try2)

    # First approach
    imgs.sort do(x, y: SourceImage) -> int:
        max(y.dstBounds.width, y.dstBounds.height) - max(x.dstBounds.width, x.dstBounds.height)
    p.packImagesToSpritesheets(imgs, try1)

    # Second approach
    imgs.sort do(x, y: SourceImage) -> int:
        y.dstBounds.width * y.dstBounds.height - x.dstBounds.width * x.dstBounds.height
    p.packImagesToSpritesheets(imgs, try2)

    # Choose better approach
    if try1.len < try2.len:
        # Redo try1 again
        imgs.sort do(x, y: SourceImage) -> int:
            max(y.dstBounds.width, y.dstBounds.height) - max(x.dstBounds.width, x.dstBounds.height)
        try1.setLen(0)
        p.packImagesToSpritesheets(imgs, try1)
        result = try1
    else:
        result = try2

proc composeAndWrite(ss: SpriteSheet, images: seq[SourceImage]) {.gcsafe.} = # seq is better than openarray for spawn
    var data = newString(ss.size.width * ss.size.height * 4)
    for im in images:
        var png = loadPNG32AUX(im.path)

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

    if ss.useWebp:
        var pngBuff = cast[ptr uint8](addr data[0])
        var encBuff: ptr uint8
        let c = 4.cint
        var size: cint
        if ss.webpLossless:
            size = webpEncodeLosslessRGBA(pngBuff, ss.size.width.cint, ss.size.height.cint,
                ss.size.width.cint * c, addr encBuff)
        else:
            size = webpEncodeRGBA(pngBuff, ss.size.width.cint, ss.size.height.cint,
                ss.size.width.cint * c, ss.webpQuality, addr encBuff)

        var strm = newFileStream(ss.path, fmWrite)
        strm.writeData(encBuff, size)
        strm.close()

        webpFree(encBuff)
    else:
        discard savePNG32AUX(ss.path, data, ss.size.width, ss.size.height)
    data = ""

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

    info "Packing category ", (if category.len == 0: "nil" else: category), " with ", occurences.len, " images, ", sourceImages.len, " unique"

    var s = epochTime()
    readSourceInfo(sourceImages)
    var e = epochTime()
    info "Images read (seconds): ", e - s

    for i in 0 ..< sourceImages.len:
        calculateTargetSize(sourceImages[i])

    var spriteSheets = packer.assignImagesToSpritesheets(sourceImages)
    optimizeLastSheet(spriteSheets[^1], sourceImages)
    let spriteSheetIdxOffset = packer.spriteSheets.len
    for i, ss in spriteSheets:
        ss.size.width = ss.packer.width
        ss.size.height = ss.packer.height
        ss.useWebp = packer.useWebp
        ss.webpQuality = packer.webpQuality
        ss.packer = nil
        ss.path = packer.outputPrefix & $(spriteSheetIdxOffset + i)

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
