// ~/.config/quickshell/lyrics/Constellation.qml
// One lyric line drawn as a constellation: each word is a star, linked in order.
import QtQuick
import QtQuick.Effects

Item {
    id: c

    property var line: null       // { t, end, words: [{ text, t }] }
    property bool shown: false
    property int wordIdx: -1
    property real now: 0
    property bool dimmed: false
    property color accent: "#b388ff"
    property string fontFamily: "Inter"
    property int fontSize: 72      // size of the current word
    property real beat: 0          // 0..1 bass level, fast (from cava)
    property real energy: 0.5      // 0..1 loudness, slow (from cava)
    property real beatPulse: 0.3   // how much the current word grows on a beat
    property real mood: 0.7        // 0 calm … 1 energetic: shapes how words arrive
    // whole line: smaller in quiet parts, bigger in loud parts (0.85 .. 1.15)
    readonly property real loudScale: 0.85 + 0.3 * Math.min(1, energy * 1.6)

    // anticipation: a faint "ghost" star fades in where the next word will land
    property bool ghost: true
    property int ghostLeadMs: 700  // how long before the word the ghost starts to appear
    readonly property int nextIdx: shown && line ? wordIdx + 1 : -1
    readonly property real ghostK: ghost && nextIdx >= 0 && nextIdx < line.words.length && nextIdx < pts.length
        ? Math.max(0, Math.min(1, 1 - (line.words[nextIdx].t - now) / ghostLeadMs)) : 0

    property var pts: []          // star positions
    property var extra: []        // extra cross-links [[i, j], ...]

    opacity: shown ? (dimmed ? 0.5 : 1) : 0
    visible: opacity > 0.01
    Behavior on opacity { NumberAnimation { duration: c.shown ? 250 : 700; easing.type: Easing.OutCubic } }

    onLineChanged: layout()
    onWidthChanged: layout()
    onHeightChanged: layout()
    onWordIdxChanged: cv.requestPaint()
    onNowChanged: {
        // only repaint while the newest link is still "drawing"
        if (shown && line && wordIdx >= 1 && wordIdx < line.words.length
                && now - line.words[wordIdx].t < 400)
            cv.requestPaint()
    }

    function rng(seed) {
        let s = seed | 0
        return function () {
            s = (s + 0x6D2B79F5) | 0
            let t = Math.imul(s ^ (s >>> 15), 1 | s)
            t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
            return ((t ^ (t >>> 14)) >>> 0) / 4294967296
        }
    }

    function layout() {
        if (!line || width <= 0 || height <= 0) { pts = []; extra = []; cv.requestPaint(); return }
        const r = rng(Math.round(line.t) * 7919 + 17)
        const n = line.words.length
        const k = fontSize / 46        // spread stars further apart for bigger text
        const w = Math.min(width * 0.82, 200 + n * 150 * k)
        const x0 = (width - w) / 2 + (r() - 0.5) * width * 0.1
        const yMid = height * (0.4 + r() * 0.2)
        const m = 70 * k               // keep words away from the screen edges
        const p = []
        for (let i = 0; i < n; i++) {
            const fx = n === 1 ? 0.5 : i / (n - 1)
            const x = Math.max(m, Math.min(width - m, x0 + fx * w + (r() - 0.5) * 50))
            const y = Math.max(m * 1.6, Math.min(height - m, yMid + (r() - 0.5) * height * 0.3))
            p.push(Qt.point(x, y))
        }
        const e = []
        for (let i = 2; i < n; i++) if (r() < 0.3) e.push([i - 2, i])
        pts = p
        extra = e
        cv.requestPaint()
    }

    Canvas {
        id: cv
        anchors.fill: parent
        renderTarget: Canvas.FramebufferObject
        renderStrategy: Canvas.Cooperative
        antialiasing: true                 // smooth star links

        onPaint: {
            const ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            const P = c.pts
            const L = c.line
            const wi = Math.min(c.wordIdx, P.length - 1)
            if (!L || wi < 1) return

            ctx.lineWidth = 1.2
            ctx.strokeStyle = "rgba(255,255,255,0.45)"
            ctx.beginPath()
            ctx.moveTo(P[0].x, P[0].y)
            for (let i = 1; i <= wi; i++) {
                let k = 1
                if (i === wi && c.shown) k = Math.max(0, Math.min(1, (c.now - L.words[i].t) / 300))
                ctx.lineTo(P[i - 1].x + (P[i].x - P[i - 1].x) * k,
                           P[i - 1].y + (P[i].y - P[i - 1].y) * k)
            }
            ctx.stroke()

            ctx.strokeStyle = "rgba(255,255,255,0.18)"
            ctx.beginPath()
            for (const [a, b] of c.extra) {
                if (b >= wi) continue
                ctx.moveTo(P[a].x, P[a].y)
                ctx.lineTo(P[b].x, P[b].y)
            }
            ctx.stroke()
        }
    }

    // ghost star for the upcoming word (grows and brightens as its moment approaches)
    Text {
        visible: c.ghostK > 0.01
        x: (c.nextIdx >= 0 && c.nextIdx < c.pts.length ? c.pts[c.nextIdx].x : 0) - width / 2
        y: (c.nextIdx >= 0 && c.nextIdx < c.pts.length ? c.pts[c.nextIdx].y : 0) - height / 2
        text: "✦"
        renderType: Text.CurveRendering
        color: c.accent
        font.pixelSize: c.fontSize * 0.2
        opacity: c.ghostK * 0.55
        scale: 0.5 + 0.5 * c.ghostK
    }

    Repeater {
        model: c.line ? c.line.words : []

        delegate: Item {
            id: star
            required property var modelData
            required property int index

            readonly property bool lit: index <= c.wordIdx
            readonly property bool current: c.shown && index === c.wordIdx
            readonly property point p: index < c.pts.length ? c.pts[index] : Qt.point(-999, -999)

            x: p.x
            y: p.y
            opacity: lit ? 1 : 0
            // energetic: quick (so the pop is visible); calm: a slower fade-in
            Behavior on opacity { NumberAnimation { duration: Math.max(80, 400 - 400 * c.mood) } }

            // glow flare when the word lands (1 → 0 over 600 ms)
            property real flare: 0
            onCurrentChanged: if (current) flareAnim.restart()
            NumberAnimation { id: flareAnim; target: star; property: "flare"; from: 1; to: 0; duration: 600; easing.type: Easing.OutQuad }

            Text {
                anchors.centerIn: parent
                text: "✦"
                renderType: Text.CurveRendering    // sharp at any scale
                color: star.current ? c.accent : "white"
                font.pixelSize: star.current ? c.fontSize * 0.5 : c.fontSize * 0.2
                Behavior on font.pixelSize { NumberAnimation { duration: 350; easing.type: Easing.OutBack } }
                // current star pulses with the beat
                scale: star.current ? 1 + c.beat * c.beatPulse * 1.5 : 1
            }

            Text {
                id: wordText
                anchors.horizontalCenter: parent.horizontalCenter
                // keep the word on screen: slide it sideways if its widest size
                // (pop overshoot + beat + loud scaling ≈ 1.5×) would cross a screen edge
                readonly property real maxS: star.current ? 1.5 : 0.34 * 1.15
                readonly property real halfW: implicitWidth * maxS / 2
                readonly property real edge: 32
                anchors.horizontalCenterOffset: {
                    const over = star.x + halfW - (c.width - edge)
                    const under = edge - (star.x - halfW)
                    return over > 0 ? -over : (under > 0 ? under : 0)
                }
                Behavior on anchors.horizontalCenterOffset { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                anchors.bottom: parent.verticalCenter
                anchors.bottomMargin: 12
                transformOrigin: Item.Bottom
                text: star.modelData.text
                renderType: Text.CurveRendering    // sharp at any scale (pop-in, beat pulse)
                font.family: c.fontFamily
                font.pixelSize: c.fontSize
                font.weight: Font.DemiBold
                color: star.current ? "white" : Qt.rgba(1, 1, 1, 0.6)
                scale: star.current ? 1 : 0.34
                // arrival follows the song's mood: energetic → fast springy pop with overshoot;
                // calm → slow, smooth grow with no bounce. Shrinking afterwards is always smooth.
                Behavior on scale {
                    NumberAnimation {
                        duration: star.current ? 900 - 540 * c.mood : 350
                        easing.type: star.current ? Easing.OutBack : Easing.OutCubic
                        easing.overshoot: 3.0 * c.mood
                    }
                }
                // music-driven size on top of the current/past scale (no Behavior: follows the beat)
                transform: Scale {
                    origin.x: wordText.width / 2
                    origin.y: wordText.height
                    readonly property real s: c.loudScale * (star.current ? 1 + c.beat * c.beatPulse : 1)
                    xScale: s
                    yScale: s
                }

                layer.enabled: star.current
                // render the glowing word at 2× so it stays crisp when the pop-in /
                // beat pulse scales it up to ~1.5×
                layer.textureSize: Qt.size(Math.ceil(width * 2), Math.ceil(height * 2))
                layer.smooth: true
                layer.effect: MultiEffect {
                    // glow scales with the text and is a lighter tint of the song colour,
                    // so it stays visible over the ambient light in fullscreen
                    autoPaddingEnabled: true
                    shadowEnabled: true
                    shadowColor: Qt.lighter(c.accent, 1.35)
                    shadowOpacity: Math.min(1, 0.85 + c.beat * 0.3 + star.flare * 0.3)
                    shadowBlur: 1.0
                    blurMax: Math.round(c.fontSize * 0.6)
                    shadowScale: 1.02 + c.beat * 0.04 + star.flare * 0.08   // swells on beats, flares on pop-in
                    brightness: star.flare * 0.25
                    shadowHorizontalOffset: 0
                    shadowVerticalOffset: 0
                }
            }
        }
    }
}
