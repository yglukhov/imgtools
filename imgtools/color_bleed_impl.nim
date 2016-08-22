
proc colorBleed*(image: var string, width, height: int) =
    let N = width * height;

    var opaque = newSeq[uint8](N)
    var loose = newSeq[bool](N)

    var pending = newSeqOfCap[int](N)
    var pendingNext = newSeqOfCap[int](N)

    const offsets = [
        [-1, -1],
        [ 0, -1],
        [ 1, -1],
        [-1,  0],
        [ 1,  0],
        [-1,  1],
        [ 0,  1],
        [ 1,  1]
    ]

    var i = 0
    var j = 3
    while i < N:
        if ord(image[j]) == 0:
            var isLoose = true;

            var x = i mod width
            var y = i div width

            for k in 0 ..< 8:
                let s = offsets[k][0]
                let t = offsets[k][1]

                if (x + s >= 0 and x + s < width and y + t >= 0 and y + t < height):
                    let index = j + 4 * (s + t * width);

                    if (ord(image[index + 3]) != 0):
                        isLoose = false;
                        break;

            if (not isLoose):
                pending.add(i);
            else:
                loose[i] = true;
        else:
            opaque[i] = 0xFF;
        inc i
        j += 4

    while (pending.len > 0):
        pendingNext.setLen(0)

        for p in 0 ..< pending.len:
            let i = pending[p] * 4;
            let j = pending[p];

            let x = j mod width;
            let y = j div width;

            var r = 0;
            var g = 0;
            var b = 0;

            var count = 0;

            for k in 0 ..< 8:
                let s = offsets[k][0];
                var t = offsets[k][1];

                if x + s >= 0 and x + s < width and y + t >= 0 and y + t < height:
                    t *= width;

                    if ((opaque[j + s + t] and 1) != 0):
                        let index = i + 4 * (s + t);

                        r += ord(image[index + 0])
                        g += ord(image[index + 1])
                        b += ord(image[index + 2])

                        inc count

            if (count > 0):
                image[i + 0] = char(r div count)
                image[i + 1] = char(g div count)
                image[i + 2] = char(b div count)

                opaque[j] = 0xFE

                for k in 0 ..< 8:
                    let s = offsets[k][0];
                    let t = offsets[k][1];

                    if (x + s >= 0 and x + s < width and y + t >= 0 and y + t < height):
                        let index = j + s + t * width;

                        if (loose[index]):
                            pendingNext.add(index);
                            loose[index] = false;
            else:
                pendingNext.add(j);

        if (pendingNext.len > 0):
            for p in 0 ..< pending.len:
                opaque[pending[p]] = opaque[pending[p]] shr 1

        swap(pending, pendingNext)
