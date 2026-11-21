.pragma library
// Lays words out in centred rows, wrapping at maxW.
//   widths: width of each word, space: gap between words, lineH: row height.
// Returns { pos: [{ x, y }] (top-left of each word), w, h } for the whole block.
function layout(widths, space, maxW, lineH) {
    const rows = []
    let cur = [], curW = 0
    for (let i = 0; i < widths.length; i++) {
        const add = (cur.length ? space : 0) + widths[i]
        if (cur.length && curW + add > maxW) {
            rows.push({ items: cur, w: curW })
            cur = []
            curW = 0
        }
        curW += (cur.length ? space : 0) + widths[i]
        cur.push(i)
    }
    if (cur.length) rows.push({ items: cur, w: curW })

    const pos = new Array(widths.length)
    for (let r = 0; r < rows.length; r++) {
        let x = (maxW - rows[r].w) / 2
        for (const i of rows[r].items) {
            pos[i] = { x: x, y: r * lineH }
            x += widths[i] + space
        }
    }
    return { pos: pos, w: maxW, h: rows.length * lineH }
}
