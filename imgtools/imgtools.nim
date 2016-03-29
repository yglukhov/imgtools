import stb_image_resize

type Rect* = tuple[x, y, width, height: int]

const comp = 4

proc resizeImage*(input: string, inWidth, inHeight: int, output: var string, outWidth, outHeight: int) =
    discard stbir_resize_uint8(cast[ptr uint8] (unsafeAddr input[0]), inWidth.cint, inHeight.cint, 0,
        cast[ptr uint8](addr output[0]), outWidth.cint, outHeight.cint, 0, comp)

proc resizeImage*(input: string, inWidth, inHeight: int,
                    output: var string, outWidth, outHeight,
                    inX, inY, inW, inH,
                    outX, outY, outW, outH: int
                    ) =
    let inStart = cast[ptr uint8](unsafeAddr input[(inY * inWidth + inX) * comp])
    let outStart = cast[ptr uint8](addr output[(outY * outWidth + outX) * comp])
    discard stbir_resize_uint8(
        inStart, inW.cint, inH.cint, inWidth.cint * comp,
        outStart, outW.cint, outH.cint, outWidth.cint * comp, comp)

proc blitImage*(toData: var string, toWidth, toHeight, toX, toY: int, fromData: string, fromWidth, fromHeight, fromX, fromY, width, height: int) =
    const comp = 4
    for y in 0 ..< height:
        for x in 0 ..< width:
            let fromOff = ((fromY + y) * fromWidth + fromX + x) * comp
            let toOff = ((toY + y) * toWidth + toX + x) * comp
            for c in 0 ..< comp:
                toData[toOff + c] = fromData[fromOff + c]

proc imageBoundsNoColorBleed*(data: string, width, height: int): Rect =
    var minX = width
    var minY = height
    var maxX = 0
    var maxY = 0

    for x in 0 ..< width:
        for y in 0 ..< height:
            let off = (y * width + x) * 4
            if data[off].uint8 != 0 or data[off + 1].uint8 != 0 or data[off + 2].uint8 != 0 or data[off + 3].uint8 != 0:
                if x > maxX: maxX = x
                if x < minX: minX = x
                if y > maxY: maxY = y
                if y < minY: minY = y

    result = (minX, minY, maxX - minX + 1, maxY - minY + 1)

proc imageBounds*(data: string, width, height: int): Rect =
    var minX = width
    var minY = height
    var maxX = 0
    var maxY = 0

    for x in 0 ..< width:
        for y in 0 ..< height:
            let off = (y * width + x) * 4
            if data[off + 3].uint8 != 0:
                if x > maxX: maxX = x
                if x < minX: minX = x
                if y > maxY: maxY = y
                if y < minY: minY = y

    result = (minX, minY, maxX - minX + 1, maxY - minY + 1)

proc extrudeBorderPixels*(data: var string, dw, dh, x, y, w, h, extrusion: int) =
    const pixelComponents = 4

    # Top Border
    for row in y ..< y + extrusion:
        for col in x + extrusion ..< x + w - extrusion:
            let
                pixpos = (row * dw + col) * pixelComponents
                srcpos = ((y + extrusion) * dw + col) * pixelComponents
            for i in 0 .. 3: data[pixpos + i] = data[srcpos + i]

    # Right Border
    for row in y + extrusion ..< y + h - extrusion:
        for col in x + w - extrusion ..< x + w:
            let
                pixpos = (row * dw + col) * pixelComponents
                srcpos = (row * dw + x + w - extrusion - 1) * pixelComponents
            for i in 0 .. 3: data[pixpos + i] = data[srcpos + i]

    # Bottom Border
    for row in y + h - extrusion ..< y + h:
        for col in x + extrusion ..< x + w - extrusion:
            let
                pixpos = (row * dw + col) * pixelComponents
                srcpos = ((y + h - extrusion - 1) * dw + col) * pixelComponents
            for i in 0 .. 3: data[pixpos + i] = data[srcpos + i]

    # Left Border
    for row in y + extrusion ..< y + h - extrusion:
        for col in x ..< x + extrusion:
            let
                pixpos = (row * dw + col) * pixelComponents
                srcpos = (row * dw + x + extrusion) * pixelComponents
            for i in 0 .. 3: data[pixpos + i] = data[srcpos + i]

    # Top-Left Corner
    for row in y ..< y + extrusion:
        for col in x ..< x + extrusion:
            let
                pixpos = (row * dw + col) * pixelComponents
                srcpos = ((y + extrusion) * dw + x + extrusion) * pixelComponents
            for i in 0 .. 3: data[pixpos + i] = data[srcpos + i]

    # Top-Right Corner
    for row in y ..< y + extrusion:
        for col in x + w - extrusion ..< x + w:
            let
                pixpos = (row * dw + col) * pixelComponents
                srcpos = ((y + extrusion) * dw + x + w - extrusion - 1) * pixelComponents
            for i in 0 .. 3: data[pixpos + i] = data[srcpos + i]

    # Bottom-Right Corner
    for row in y + h - extrusion ..< y + h:
        for col in x + w - extrusion ..< x + w:
            let
                pixpos = (row * dw + col) * pixelComponents
                srcpos = ((y + h - extrusion - 1) * dw + x + w - extrusion - 1) * pixelComponents
            for i in 0 .. 3: data[pixpos + i] = data[srcpos + i]

    # Bottom-Left Corner
    for row in y + h - extrusion ..< y + h:
        for col in x ..< x + extrusion:
            let
                pixpos = (row * dw + col) * pixelComponents
                srcpos = ((y + h - extrusion - 1) * dw + x + extrusion) * pixelComponents
            for i in 0 .. 3: data[pixpos + i] = data[srcpos + i]

proc zeroColorIfZeroAlpha*(data: var string) =
    let dataLen = data.len()
    let step = 4
    var i = step - 1
    while i < dataLen:
        if data[i].uint8 == 0:
            data[i-1] = 0.char
            data[i-2] = 0.char
            data[i-3] = 0.char
        i += step

when isMainModule:
    import nimPNG
    var png = loadPNG32("/Users/yglukhov/Projects/falcon/res/eiffel_slot/Chef/Chef31.png")
    const outWidth = 1024
    const outHeight = 1024
    var resmapledImg = newString(outWidth * outHeight * comp)

    #resizeImage(png.data, png.width, png.height, resmapledImg, outWidth, outHeight)


    resizeImage(png.data, png.width, png.height,
        resmapledImg, outWidth, outHeight,
        0, 0, 512, 512,
        0, 0, 512, 512)

    png = loadPNG32("/Users/yglukhov/Projects/falcon/res/eiffel_slot/Chef/Chef32.png")
    resizeImage(png.data, png.width, png.height,
        resmapledImg, outWidth, outHeight,
        0, 0, png.width, png.height,
        512, 0, 512, 512)

    resizeImage(png.data, png.width, png.height,
        resmapledImg, outWidth, outHeight,
        0, 0, png.width, png.height,
        512, 512, 512, 512)

    discard savePNG32("/Users/yglukhov/out.png", resmapledImg, outWidth, outHeight)
