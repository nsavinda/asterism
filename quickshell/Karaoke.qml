// ~/.config/quickshell/lyrics/Karaoke.qml
// Profile "karaoke": the whole line, centred and readable. Each word fills with light as it is
// sung, the current word lifts and glows, and the next line waits faintly underneath.
import QtQuick
import QtQuick.Effects
import "rows.js" as Rows

Item {
    id: k

    // same interface as every profile (see LyricView.qml)
    property var line: null        // { t, end, words: [{ text, t }] }
    property var nextLine: null    // the line after this one, for the preview
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

    readonly property real size: Math.round(fontSize * 0.62)
    readonly property real maxW: width * 0.8
    property var lay: ({ pos: [], w: 0, h: 0 })

    opacity: shown ? (dimmed ? 0.5 : 1) : 0
    visible: opacity > 0.01
    Behavior on opacity { NumberAnimation { duration: k.shown ? 350 : 600; easing.type: Easing.OutCubic } }

    // a new line rises in from below; a finished one drifts up as it fades
    property real lift: 0
    property bool liftAnim: true
    Behavior on lift { enabled: k.liftAnim; NumberAnimation { duration: 650; easing.type: Easing.OutCubic } }
    onShownChanged: lift = shown ? 0 : -size * 0.6

    onLineChanged: { relayout(); liftAnim = false; lift = size * 0.6; liftAnim = true; if (shown) lift = 0 }
    onWidthChanged: relayout()
    onSizeChanged: relayout()

    FontMetrics { id: fm; font.family: k.fontFamily; font.pixelSize: k.size; font.weight: Font.DemiBold }

    function relayout() {
        if (!line || width <= 0) { lay = { pos: [], w: 0, h: 0 }; return }
        lay = Rows.layout(line.words.map(w => fm.advanceWidth(w.text)), size * 0.3, maxW, size * 1.35)
    }

    Item {
        id: block
        width: k.lay.w
        height: k.lay.h
        x: (k.width - width) / 2
        y: k.height * 0.46 - height / 2 + k.lift

        Repeater {
            model: k.line ? k.line.words : []

            delegate: Item {
                id: w
                required property var modelData
                required property int index

                readonly property var p: index < k.lay.pos.length ? k.lay.pos[index] : { x: 0, y: 0 }
                readonly property bool current: k.shown && index === k.wordIdx
                readonly property real t1: index + 1 < k.line.words.length ? k.line.words[index + 1].t : k.line.end
                // 0 → 1 while the word is sung (capped so a held last word still finishes)
                readonly property real prog: !k.shown ? (index <= k.wordIdx ? 1 : 0)
                    : Math.max(0, Math.min(1, (k.now - modelData.t) / Math.max(150, Math.min(2500, t1 - modelData.t))))

                x: p.x
                y: p.y
                width: base.implicitWidth
                height: base.implicitHeight

                property real pop: current ? 1 : 0
                Behavior on pop { NumberAnimation { duration: 260 + 300 * (1 - k.mood); easing.type: Easing.OutBack; easing.overshoot: 1 + 2 * k.mood } }
                // lift, not grow: growing would close the gap to the neighbouring words
                transform: Translate { y: -k.size * w.pop * (0.1 + k.beat * k.beatPulse * 0.35) }

                Text {                       // unsung
                    id: base
                    text: w.modelData.text
                    renderType: Text.CurveRendering
                    font.family: k.fontFamily
                    font.pixelSize: k.size
                    font.weight: Font.DemiBold
                    color: Qt.rgba(1, 1, 1, 0.26)
                }
                Item {                       // sung part, revealed left to right
                    width: base.width * w.prog
                    height: base.height
                    clip: true
                    Text {
                        text: w.modelData.text
                        renderType: Text.CurveRendering
                        font: base.font
                        color: w.current ? Qt.tint("white", Qt.alpha(k.accent, 0.3)) : Qt.rgba(1, 1, 1, 0.92)
                    }
                }

                layer.enabled: current
                layer.textureSize: Qt.size(Math.ceil(width * 2), Math.ceil(height * 2))
                layer.smooth: true
                layer.effect: MultiEffect {
                    autoPaddingEnabled: true
                    shadowEnabled: true
                    shadowColor: Qt.lighter(k.accent, 1.35)
                    shadowOpacity: Math.min(1, 0.8 + k.beat * 0.3)
                    shadowBlur: 1.0
                    blurMax: Math.round(k.size * 0.7)
                    shadowScale: 1.02 + k.beat * 0.04
                    shadowHorizontalOffset: 0
                    shadowVerticalOffset: 0
                }
            }
        }
    }

    // the next line, waiting underneath
    Text {
        width: k.maxW
        x: (k.width - width) / 2
        y: block.y + block.height + k.size * 0.45
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
        text: k.nextLine ? k.nextLine.words.map(x => x.text).join(" ") : ""
        renderType: Text.CurveRendering
        font.family: k.fontFamily
        font.pixelSize: Math.round(k.size * 0.5)
        font.weight: Font.Medium
        color: "white"
        opacity: k.ghost && k.shown ? 0.22 : 0
        Behavior on opacity { NumberAnimation { duration: 500 } }
    }
}
