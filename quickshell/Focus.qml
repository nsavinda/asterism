// ~/.config/quickshell/lyrics/Focus.qml
// Profile "focus": big text, a short phrase at a time, like a lyric video. The line is cut into
// phrases of one to four words the way it would be sung (at punctuation and breaths, never right
// after "the" or "to"). Words in the phrase light up as they are sung, quick little words sit
// smaller than held ones, a held note slowly swells, and finished phrases scroll up and fade.
import QtQuick
import QtQuick.Effects

Item {
    id: f

    // same interface as every profile (see LyricView.qml)
    property var line: null
    property var nextLine: null
    property bool shown: false
    property int wordIdx: -1
    property real now: 0
    property bool dimmed: false
    property color accent: "#b388ff"
    property string fontFamily: "Inter"
    property int fontSize: 72
    property real beat: 0
    property real energy: 0.5
    property real beatPulse: 0.3
    property real mood: 0.7
    property bool ghost: true

    readonly property real big: Math.round(fontSize * 1.3)
    readonly property real cy: height * 0.46
    readonly property int ease: Math.round(800 - 380 * mood)   // calm songs move slower

    property var chunks: []      // [{ words: [{ text, t, dur, x, k }], w }]
    property var chunkOf: []     // word index → phrase index
    readonly property int cur: !chunks.length ? -1
        : wordIdx < 0 ? 0 : (chunkOf[Math.min(wordIdx, chunkOf.length - 1)] || 0)
    // anticipation: the next phrase brightens a little just before it starts
    readonly property real ghostK: cur >= 0 && cur + 1 < chunks.length
        ? Math.max(0, Math.min(1, 1 - (chunks[cur + 1].words[0].t - now) / 700)) : 0

    opacity: shown ? (dimmed ? 0.5 : 1) : 0
    visible: opacity > 0.01
    Behavior on opacity { NumberAnimation { duration: f.shown ? 300 : 600; easing.type: Easing.OutCubic } }
    property real lift: shown ? 0 : -big * 0.4
    Behavior on lift { NumberAnimation { duration: 700; easing.type: Easing.OutCubic } }

    onLineChanged: relayout()
    onBigChanged: relayout()
    onFontFamilyChanged: relayout()

    FontMetrics { id: fm; font.family: f.fontFamily; font.pixelSize: f.big; font.weight: Font.Bold }

    // words a phrase should not end on
    function glue(t) {
        return /^(a|an|the|to|of|in|on|at|by|for|from|with|into|and|but|or|so|if|my|your|our|his|her|their|its|this|that|i|i'm|i'd|i'll|we're|you're)$/i
            .test(t.replace(/[^\w']/g, ""))
    }

    function relayout() {
        const L = line
        if (!L || !L.words.length) { chunks = []; chunkOf = []; return }
        const W = L.words, n = W.length
        const out = [], of = []
        let s = 0, chars = 0
        for (let i = 0; i < n; i++) {
            chars += W[i].text.length
            const next = i + 1 < n ? W[i + 1] : null
            const count = i - s + 1
            const punct = /[,.;:!?…)\]]$/.test(W[i].text)
            const gap = next ? next.t - W[i].t : 0
            const breath = gap > 1100                              // a pause
            const held = gap >= 750 && count >= 2                  // a long note closes a phrase
            let cut = !next || punct || breath || held || count >= 3 || chars + next.text.length > 14
            // "take you to | the place", not "take you to the | place"
            if (cut && next && !punct && !breath && glue(W[i].text) && count < 4 && chars + next.text.length <= 17)
                cut = false
            of.push(out.length)
            if (cut) { out.push(build(W, s, i, L.end)); s = i + 1; chars = 0 }
        }
        chunkOf = of
        chunks = out
    }

    function build(W, s, e, end) {
        const space = fm.advanceWidth(" ") * 1.15
        const words = []
        let x = 0
        for (let i = s; i <= e; i++) {
            const dur = (i + 1 < W.length ? W[i + 1].t : end) - W[i].t
            // quick words sit smaller, held words carry the weight
            const k = 0.8 + 0.2 * Math.max(0, Math.min(1, (dur - 160) / 540))
            if (words.length) x += space * (k + words[words.length - 1].k) / 2
            words.push({ text: W[i].text, t: W[i].t, dur: dur, x: x, k: k, i: i })
            x += fm.advanceWidth(W[i].text) * k
        }
        return { words: words, w: x }
    }

    Repeater {
        model: f.chunks

        delegate: Item {
            id: ch
            required property var modelData
            required property int index

            readonly property int rel: index - f.cur          // 0 = now, -1 = just sung, 1 = next
            readonly property bool live: f.shown && rel === 0
            readonly property real fit: Math.min(1, f.width * 0.88 / Math.max(1, modelData.w))

            width: modelData.w
            height: fm.height
            x: (f.width - width) / 2
            y: f.cy - height / 2 + f.lift
               + (rel < 0 ? -f.big * (1.0 + 0.45 * (-rel - 1)) : rel > 0 ? f.big * (0.95 + 0.45 * (rel - 1)) : 0)
            scale: fit * (rel === 0 ? 1 : rel === -1 ? 0.5 : 0.42)
            opacity: rel === 0 ? 1 : rel === -1 ? 0.22 : rel === 1 && f.ghost ? 0.1 + 0.18 * f.ghostK : 0
            visible: opacity > 0.005

            Behavior on y { NumberAnimation { duration: f.ease; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: f.ease; easing.type: Easing.OutCubic } }
            Behavior on opacity { NumberAnimation { duration: f.ease * 0.8 } }

            // the beat, gently, on the whole phrase
            transform: Scale {
                origin.x: ch.width / 2; origin.y: ch.height / 2
                xScale: ch.live ? 1 + f.beat * f.beatPulse * 0.25 : 1
                yScale: xScale
            }

            // glow on the phrase being sung; fades out (rather than snapping off) as it scrolls away
            property real glow: live ? 1 : 0
            Behavior on glow { NumberAnimation { duration: 450 } }
            layer.enabled: glow > 0.01
            layer.textureSize: Qt.size(Math.ceil(width * 1.5), Math.ceil(height * 1.5))
            layer.smooth: true
            layer.effect: MultiEffect {
                autoPaddingEnabled: true
                shadowEnabled: true
                shadowColor: Qt.lighter(f.accent, 1.3)
                shadowOpacity: ch.glow * Math.min(1, 0.75 + f.beat * 0.3)
                shadowBlur: 1.0
                blurMax: Math.round(f.big * 0.45)
                shadowScale: 1.02 + f.beat * 0.04
                shadowHorizontalOffset: 0
                shadowVerticalOffset: 0
            }

            Repeater {
                model: ch.modelData.words

                delegate: Text {
                    id: w
                    required property var modelData

                    readonly property bool sung: modelData.i <= f.wordIdx
                    readonly property bool current: f.shown && modelData.i === f.wordIdx
                    // a held note swells while it is sung and settles after
                    readonly property real swell: {
                        if (modelData.dur < 650 || !sung) return 0
                        const p = (f.now - modelData.t) / modelData.dur
                        return p <= 1 ? Math.max(0, p) : Math.max(0, 1 - (p - 1) * modelData.dur / 450)
                    }

                    text: modelData.text
                    renderType: Text.CurveRendering
                    font.family: f.fontFamily
                    font.pixelSize: Math.round(f.big * modelData.k)
                    font.weight: Font.Bold
                    color: !sung ? Qt.rgba(1, 1, 1, 0.24)
                         : current ? Qt.tint("white", Qt.alpha(f.accent, 0.2)) : "white"
                    Behavior on color { ColorAnimation { duration: 240 } }

                    // share one baseline whatever the size; unsung words sit a touch lower
                    x: modelData.x
                    y: fm.ascent * (1 - modelData.k) + up
                    property real up: sung ? 0 : f.big * 0.06
                    Behavior on up { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }

                    transform: Scale {
                        origin.x: w.width / 2; origin.y: w.height * 0.75
                        xScale: 1 + 0.07 * w.swell
                        yScale: xScale
                    }
                }
            }
        }
    }
}
