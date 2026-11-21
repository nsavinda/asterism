// ~/.config/quickshell/lyrics/Focus.qml
// Profile "focus": one word at a time, very large, like a kinetic lyric video. Each word pops in
// at the centre with a slight tilt; the previous two drift up as fading echoes.
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

    readonly property real big: Math.round(fontSize * 1.55)
    readonly property real cy: height * 0.46

    // anticipation: the next word, small and faint, below the current one
    readonly property int nextIdx: shown && line ? wordIdx + 1 : -1
    readonly property real ghostK: ghost && line && nextIdx >= 0 && nextIdx < line.words.length
        ? Math.max(0, Math.min(1, 1 - (line.words[nextIdx].t - now) / 700)) : 0

    opacity: shown ? (dimmed ? 0.5 : 1) : 0
    visible: opacity > 0.01
    Behavior on opacity { NumberAnimation { duration: f.shown ? 200 : 450; easing.type: Easing.OutCubic } }
    property real lift: shown ? 0 : -big * 0.5
    Behavior on lift { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }

    // stable pseudo-random 0..1 per word, so a line always moves the same way
    function hash(n) {
        const x = Math.sin(n * 12.9898 + (line ? line.t : 0) * 0.00178) * 43758.5453
        return x - Math.floor(x)
    }

    Repeater {
        model: f.line ? f.line.words : []

        delegate: Text {
            id: w
            required property var modelData
            required property int index

            readonly property int age: f.wordIdx - index          // 0 = current, 1-2 = echoes
            readonly property bool current: f.shown && age === 0
            readonly property real fit: Math.min(1, f.width * 0.86 / Math.max(1, implicitWidth))
            readonly property real tilt: (f.hash(index) - 0.5) * 9 * (0.4 + f.mood)

            text: modelData.text
            renderType: Text.CurveRendering
            font.family: f.fontFamily
            font.pixelSize: f.big
            font.weight: Font.Bold
            color: age === 0 ? "white" : Qt.tint(Qt.rgba(1, 1, 1, 0.8), Qt.alpha(f.accent, 0.35))

            x: f.width / 2 - width / 2 + (age > 0 ? (f.hash(index + 50) - 0.5) * f.width * 0.25 : 0)
            y: f.cy - height / 2 + f.lift - (age > 0 ? f.big * (0.55 + 0.45 * age) : age < 0 ? -f.big * 0.25 : 0)
            rotation: age >= 0 ? tilt * (age === 0 ? 1 : 0.4) : tilt * 2
            scale: fit * (age < 0 ? 0.55 : age === 0 ? 1 : age === 1 ? 0.38 : 0.26)
            opacity: age < 0 ? 0 : age === 0 ? 1 : age === 1 ? 0.3 : age === 2 ? 0.1 : 0
            visible: opacity > 0.01 || age >= 0 && age <= 3

            // energetic songs: fast, springy arrival; calm songs: slower and smooth
            Behavior on scale { NumberAnimation { duration: w.current ? 700 - 420 * f.mood : 450; easing.type: w.current ? Easing.OutBack : Easing.OutCubic; easing.overshoot: 1 + 2.2 * f.mood } }
            Behavior on y { NumberAnimation { duration: 520; easing.type: Easing.OutCubic } }
            Behavior on x { NumberAnimation { duration: 520; easing.type: Easing.OutCubic } }
            Behavior on rotation { NumberAnimation { duration: 520; easing.type: Easing.OutCubic } }
            Behavior on opacity { NumberAnimation { duration: w.current ? 140 : 420 } }

            // beat on top, no smoothing so it follows the music
            transform: Scale {
                origin.x: w.width / 2; origin.y: w.height / 2
                xScale: w.current ? 1 + f.beat * f.beatPulse * 0.8 : 1
                yScale: xScale
            }

            layer.enabled: current
            layer.textureSize: Qt.size(Math.ceil(width * 1.6), Math.ceil(height * 1.6))
            layer.smooth: true
            layer.effect: MultiEffect {
                autoPaddingEnabled: true
                shadowEnabled: true
                shadowColor: Qt.lighter(f.accent, 1.3)
                shadowOpacity: Math.min(1, 0.85 + f.beat * 0.3)
                shadowBlur: 1.0
                blurMax: Math.round(f.big * 0.5)
                shadowScale: 1.02 + f.beat * 0.05
                shadowHorizontalOffset: 0
                shadowVerticalOffset: 0
            }
        }
    }

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        y: f.cy + f.big * 0.75 + f.lift
        text: f.nextIdx >= 0 && f.line && f.nextIdx < f.line.words.length ? f.line.words[f.nextIdx].text : ""
        renderType: Text.CurveRendering
        font.family: f.fontFamily
        font.pixelSize: Math.round(f.fontSize * 0.32)
        font.weight: Font.Medium
        color: f.accent
        opacity: f.ghostK * 0.45
        scale: 0.8 + 0.2 * f.ghostK
    }
}
