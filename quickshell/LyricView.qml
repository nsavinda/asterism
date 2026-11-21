// ~/.config/quickshell/lyrics/LyricView.qml
// One lyric line, drawn by the chosen profile. Every profile file has the same properties,
// so switching is just loading another file and binding them through.
import QtQuick

Item {
    id: v

    property string profile: "constellation"
    readonly property var files: ({
        constellation: "Constellation.qml",   // words as stars, linked into a constellation
        karaoke: "Karaoke.qml",               // the whole line, words fill with light as sung
        focus: "Focus.qml",                   // one huge word at a time, kinetic
        wave: "Wave.qml"                      // words rise out of a swell that moves with the music
    })

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

    Loader {
        anchors.fill: parent
        source: v.files[v.profile] || v.files.constellation
        onLoaded: {
            for (const key of ["fontFamily", "fontSize", "accent", "mood", "ghost", "dimmed", "nextLine",
                               "line", "now", "wordIdx", "shown", "beat", "energy", "beatPulse"])
                item[key] = Qt.binding(function () { return v[key] })
        }
    }
}
