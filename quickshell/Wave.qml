// ~/.config/quickshell/lyrics/Wave.qml
// Profile "wave": the line floats on a slow swell. Words rise out of it as they are sung and
// keep bobbing, the swell grows with the loudness, and the bass sends a ripple through it.
import QtQuick
import QtQuick.Effects
import "rows.js" as Rows

Item {
    id: v

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

    readonly property real size: Math.round(fontSize * 0.7)
    readonly property real maxW: width * 0.78
    property var lay: ({ pos: [], w: 0, h: 0 })

    // the swell: phase follows song time (stops when paused), height follows loudness
    readonly property real phase: now / 1000 * Math.PI * 2 * (0.22 + 0.25 * mood)
    readonly property real amp: size * (0.08 + 0.22 * Math.min(1, energy * 1.4))
    readonly property real ripple: beat * beatPulse * size * 0.9

    opacity: shown ? (dimmed ? 0.5 : 1) : 0
    visible: opacity > 0.01
    Behavior on opacity { NumberAnimation { duration: v.shown ? 400 : 800; easing.type: Easing.OutCubic } }
    property real sink: shown ? 0 : size * 0.5          // a finished line sinks as it fades
    Behavior on sink { NumberAnimation { duration: 800; easing.type: Easing.InOutQuad } }

    onLineChanged: relayout()
    onWidthChanged: relayout()
    onSizeChanged: relayout()

    FontMetrics { id: fm; font.family: v.fontFamily; font.pixelSize: v.size; font.weight: Font.DemiBold }

    function relayout() {
        if (!line || width <= 0) { lay = { pos: [], w: 0, h: 0 }; return }
        lay = Rows.layout(line.words.map(w => fm.advanceWidth(w.text)), size * 0.38, maxW, size * 1.7)
    }

    Item {
        id: block
        width: v.lay.w
        height: v.lay.h
        x: (v.width - width) / 2
        y: v.height * 0.46 - height / 2 + v.sink

        Repeater {
            model: v.line ? v.line.words : []

            delegate: Text {
                id: w
                required property var modelData
                required property int index

                readonly property var p: index < v.lay.pos.length ? v.lay.pos[index] : { x: 0, y: 0 }
                readonly property bool lit: index <= v.wordIdx
                readonly property bool current: v.shown && index === v.wordIdx
                // where this word sits on the swell (x position sets its phase, so it travels)
                readonly property real wx: (p.x + width / 2) / Math.max(1, v.maxW)
                readonly property real s: Math.sin(v.phase - wx * Math.PI * 2.2)

                text: modelData.text
                renderType: Text.CurveRendering
                font.family: v.fontFamily
                font.pixelSize: v.size
                font.weight: Font.DemiBold
                // tint follows the swell: crests lean towards the song colour
                color: current ? "white" : Qt.tint(Qt.rgba(1, 1, 1, 0.85), Qt.alpha(v.accent, 0.25 + 0.25 * s))

                x: p.x
                y: p.y + rise
                // unsung words wait below the swell, invisible; sung words rise out of it
                property real rise: lit ? 0 : v.size * 0.8
                Behavior on rise { NumberAnimation { duration: 700 - 350 * v.mood; easing.type: Easing.OutBack; easing.overshoot: 1 + 1.5 * v.mood } }
                opacity: lit ? (current ? 1 : 0.78) : 0
                Behavior on opacity { NumberAnimation { duration: 350 } }

                transform: [
                    Translate { y: -w.s * v.amp - (w.current ? v.ripple : v.ripple * 0.35) },
                    Rotation { origin.x: w.width / 2; origin.y: w.height; angle: Math.cos(v.phase - w.wx * Math.PI * 2.2) * 4 * (0.3 + v.mood) },
                    Scale { origin.x: w.width / 2; origin.y: w.height; xScale: w.grow; yScale: w.grow }
                ]
                property real grow: current ? 1.22 : 1
                Behavior on grow { NumberAnimation { duration: 400; easing.type: Easing.OutBack } }

                layer.enabled: current
                layer.textureSize: Qt.size(Math.ceil(width * 2), Math.ceil(height * 2))
                layer.smooth: true
                layer.effect: MultiEffect {
                    autoPaddingEnabled: true
                    shadowEnabled: true
                    shadowColor: Qt.lighter(v.accent, 1.35)
                    shadowOpacity: Math.min(1, 0.8 + v.beat * 0.3)
                    shadowBlur: 1.0
                    blurMax: Math.round(v.size * 0.7)
                    shadowScale: 1.02 + v.beat * 0.05
                    shadowHorizontalOffset: 0
                    shadowVerticalOffset: 0
                }
            }
        }
    }
}
