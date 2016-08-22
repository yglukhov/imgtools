
proc colorBleed*(image: var string, width, height: int) =
    let N = width * height;

    var opaque = newSeq[int8](N)
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
        if cast[uint8](image[j]) == 0:
            var isLoose = true;

            var x = i mod width
            var y = i div width

            for k in 0 ..< 8:
                let s = offsets[k][0]
                let t = offsets[k][1]

                if (x + s >= 0 and x + s < width and y + t >= 0 and y + t < height):
                    let index = j + 4  * (s + t * width);
                    if (cast[uint8](image[index]) != 0):
                        isLoose = false;
                        break;

            if (not isLoose):
                pending.add(i);
            else:
                loose[i] = true;
        else:
            opaque[i] = -1;

        inc i
        j += 4

    var rad = 0
    const targetRadius = 10
    while (pending.len > 0 and rad < targetRadius):
        pendingNext.setLen(0)
        inc rad
        for p in 0 ..< pending.len:
            let i = pending[p] * 4;
            let j = pending[p];

            let x = j mod width;
            let y = j div width;

            var r = 0
            var g = 0
            var b = 0

            var count = 0

            for k in 0 ..< 8:
                let s = offsets[k][0];
                var t = offsets[k][1];

                if x + s >= 0 and x + s < width and y + t >= 0 and y + t < height:
                    t *= width;

                    if ((opaque[j + s + t] and 1) > 0):
                        let index = i + 4 * (s + t);
                        r += cast[uint8](image[index + 0]).int
                        g += cast[uint8](image[index + 1]).int
                        b += cast[uint8](image[index + 2]).int
                        inc count

            if (count != 0):
                image[i + 0] = cast[char](r div count)
                image[i + 1] = cast[char](g div count)
                image[i + 2] = cast[char](b div count)
                opaque[j] = cast[int8](0xFE)

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

