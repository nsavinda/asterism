// ~/.config/quickshell/lyrics/shell.qml   → run with:  qs -c lyrics
import QtQuick
import QtQuick.Shapes
import QtQuick.Effects
import QtQuick.Particles
import QtWebSockets
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Services.Mpris

ShellRoot {
    id: root

    // ───────── settings ─────────
    readonly property int port: 8975
    readonly property int offsetMs: 150          // + shows lyrics earlier, - later
    readonly property color accent: "#b388ff"
    readonly property string fontFamily: "Inter"  // any installed font
    readonly property int fontSize: 96            // current word size (px)
    readonly property bool musicReactive: true    // size follows the music (needs cava)
    readonly property real beatPulse: 0.3         // how much the current word grows on a beat
    readonly property bool dynamicColor: true     // take colours from the album art
    readonly property bool runningBorder: true    // light that runs around the screen edge
    readonly property int borderSpeedMs: 6000     // one full lap
    readonly property int borderWidth: 6
    readonly property int borderGlow: 64          // glow spread in px (0 = no glow)
    readonly property bool immersive: true        // fullscreen: blurred cover, ambient light, starfield
    readonly property bool beatBorder: true       // border speeds up when loud, flashes on beats
    readonly property real particleReact: 1.0     // how strongly the starfield moves with the music (0 = calm drift)
    readonly property bool ghostStars: true       // faint star shows where the next word will land
    readonly property bool dynamics: true         // calm in quiet sections, bigger effects when the song lifts
    readonly property bool ambientMonitors: true  // fullscreen: soft colour glow on the other monitors
    readonly property bool moodAdaptive: true     // calm songs: gentle & dim; energetic songs: springy & vivid
    readonly property bool bounceBeat: true       // beat pulse rises and falls like a bounce (not a flash)
    readonly property int idleHideMs: 3500        // fullscreen: hide cursor + "Esc" hint after this long
    readonly property bool interludeCard: true    // intro: title card; mid-song breaks: colour pulses harder
    readonly property int interludeMinMs: 3000    // a gap between lines this long counts as a break

    // album cover from Spotify's MPRIS info (no extension needed)
    readonly property var spotifyPlayer: Mpris.players.values.find(
        p => (p.dbusName || "").toLowerCase().includes("spotify")
          || (p.identity || "").toLowerCase().includes("spotify")) ?? null
    readonly property string coverArt: spotifyPlayer?.trackArtUrl ?? ""
    onCoverArtChanged: console.log("lyrics cover:", coverArt || "(none)")

    // live colours: song colours when available, otherwise `accent`. Fade between songs.
    property color liveAccent: accent
    property color liveAccent2: Qt.lighter(accent, 1.4)
    Behavior on liveAccent { ColorAnimation { duration: 1200 } }
    Behavior on liveAccent2 { ColorAnimation { duration: 1200 } }

    // ───────── state ─────────
    property var lines: []
    property real basePos: 0
    property real baseClock: 0
    property bool playing: false
    property real now: 0
    property int lineIdx: -1
    property int wordIdx: -1

    // Instrumental break: no line is active and the gap to the next one is long.
    property bool interlude: false
    property real gapAge: 0         // ms since the gap started
    property real gapProgress: -1   // 0…1 towards the next line; -1 after the last line
    property bool gapIntro: true    // the gap before the first line (not a mid-song break)
    // Mid-song break: 0 → 1 while it lasts. No card; the song colour pulses harder with the music.
    property real breakK: interludeCard && interlude && !gapIntro && lines.length > 0 && playing ? 1 : 0
    Behavior on breakK { NumberAnimation { duration: 700; easing.type: Easing.InOutQuad } }
    // Title card: only before the first line, and for songs with no lyrics at all (fullscreen).
    // Overlay: only briefly, so it doesn't sit on top of your windows.
    readonly property bool cardOn: interludeCard && title !== "" && (lines.length === 0
        ? fullscreen
        : interlude && gapIntro && (fullscreen || gapAge < 9000))

    // ───────── on/off ─────────
    // State file shared with the bar button: "0" = off, anything else / missing = on.
    // Toggle from a terminal or keybind:  qs -c lyrics ipc call lyrics toggle
    // Starts hidden; the state file then switches it on (into fullscreen) or keeps it off.
    property bool lyricsOn: false
    // Default mode is fullscreen (solid background, grabs keyboard). Esc drops to the
    // transparent click-through overlay. Set to false to start as the overlay instead.
    readonly property bool startFullscreen: true
    property bool fullscreen: false

    // Hot reload would start a 2nd WebSocket server while the old one still holds the
    // port. Restart instead after edits:  pkill -f "^qs -c lyrics"; qs -c lyrics &
    Component.onCompleted: Quickshell.watchFiles = false
    property string title: ""
    property string artist: ""

    FileView {
        id: stateFile
        path: Quickshell.env("HOME") + "/.local/state/lyrics-constellation"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.applyOn(text().trim() !== "0")
        onLoadFailed: root.applyOn(true)
    }

    // turning on → default (fullscreen) mode; turning off → hide everything
    function applyOn(on) {
        if (on && !root.lyricsOn) root.fullscreen = root.startFullscreen
        if (!on) root.fullscreen = false
        root.lyricsOn = on
    }

    function setOn(on) {
        applyOn(on)
        stateFile.setText(on ? "1" : "0")
    }

    IpcHandler {
        target: "lyrics"
        function toggle(): void { root.setOn(!root.lyricsOn) }
        function on(): void { root.setOn(true) }
        function off(): void { root.setOn(false) }
        function isOn(): bool { return root.lyricsOn }
        function fullscreen(): void { root.fullscreen = !root.fullscreen }
        function exitFullscreen(): void { root.fullscreen = false }
        function isFullscreen(): bool { return root.fullscreen }
        function mood(): string { return "mood " + root.mood.toFixed(2) + " dyn " + root.dyn.toFixed(2) + " beats/12s " + root.hitTimes.length + " energy " + root.energy.toFixed(2) + " base " + root.energyBase.toFixed(2) }
        function position(): string { return "line " + root.lineIdx + " word " + root.wordIdx + " at " + Math.round(root.now) + "ms" + (root.cardOn ? " | title card on" : "") + (root.breakK > 0 ? " | break " + root.breakK.toFixed(2) : "") }
    }

    // ───────── music level (cava) ─────────
    property real beat: 0       // bass, fast attack / quick decay → pulses
    property real energy: 0.5   // overall loudness, slow average → line size
    signal beatHit()

    // Song-structure dynamics: compare the current loudness with a slow (~17 s) baseline.
    // Verses sit near/below the baseline → dyn ≈ 0.3–0.65 (calm); a chorus or drop rises
    // above it → dyn up to 1.25 (effects open up). Contrast, not constant intensity.
    property real energyBase: 0.5
    readonly property real dyn: dynamics
        ? Math.max(0.3, Math.min(1.25, 0.65 + (energy - energyBase) * 5)) : 1
    readonly property real pReact: particleReact * dyn * (0.3 + mood)

    // Mood: 0 = calm … 1 = energetic, from how often bass onsets land (last ~12 s) plus the
    // loudness baseline. A heuristic — it settles ~10 s into a song. 0.7 ≈ the old fixed look.
    property var hitTimes: []
    property real trackStartMs: 0
    property real moodSmooth: 0.6
    Behavior on moodSmooth { NumberAnimation { duration: 4000; easing.type: Easing.InOutQuad } }
    readonly property real mood: moodAdaptive ? moodSmooth : 0.7
    Timer {
        interval: 1000; repeat: true; running: cava.running
        onTriggered: {
            const t = Date.now()
            root.hitTimes = root.hitTimes.filter(x => t - x < 12000)
            const span = Math.max(3, Math.min(12, (t - root.trackStartMs) / 1000))
            const rate = root.hitTimes.length / span                      // strong beats per second
            const c = x => Math.max(0, Math.min(1, x))
            root.moodSmooth = 0.7 * c((rate - 0.4) / 1.4) + 0.3 * c((root.energyBase - 0.15) / 0.25)
        }
    }

    // Bounce: each bass onset throws the pulse up and lets it fall back (a parabola, like a
    // ball under gravity) — people follow that far better than an instant flash.
    property real bounce: 0
    property real bounceAmp: 0
    property real bounceT0: 0
    property real bassPrev: 0
    readonly property int bounceMs: 250 + (1 - mood) * 220        // calm songs swell more slowly
    readonly property real pulse: bounceBeat ? bounce : beat      // what sizes follow

    Process {
        id: cava
        command: ["cava", "-p", Quickshell.shellPath("cava.conf")]
        running: root.musicReactive && win.visible && root.playing
        onRunningChanged: if (!running) { root.beat = 0; root.bounce = 0 }
        stdout: SplitParser {
            onRead: data => {
                const v = data.split(";").map(Number).filter(x => !isNaN(x))
                if (v.length < 3) return
                const bass = Math.min(1, (v[0] + v[1] + v[2]) / 300)
                const t = Date.now()
                // bass onset: a clear rise above the recent bass level
                if (bass - root.bassPrev > 0.14 && bass > 0.25 && t - root.bounceT0 >= root.bounceMs) {
                    root.bounceAmp = bass
                    root.bounceT0 = t
                    root.hitTimes.push(t)                 // feeds the mood (beats per second)
                    if (bass > 0.45) root.beatHit()       // strong ones trigger bursts
                }
                root.bassPrev = root.bassPrev * 0.6 + bass * 0.4
                const bx = (t - root.bounceT0) / root.bounceMs
                root.bounce = bx < 1 ? root.bounceAmp * 4 * bx * (1 - bx) : 0
                root.beat = bass > root.beat ? bass : root.beat * 0.86
                let sum = 0
                for (const x of v) sum += x
                root.energy = root.energy * 0.985 + (sum / v.length / 100) * 0.015
                // baseline: settles fast in a song's first seconds, then moves slowly (~17 s)
                const kb = t - root.trackStartMs < 5000 ? 0.04 : 0.001
                root.energyBase = root.energyBase * (1 - kb) + root.energy * kb
            }
        }
    }

    WebSocketServer {
        id: server
        listen: true
        host: "127.0.0.1"
        port: root.port
        accept: true
        onClientConnected: function (sock) {
            sock.onTextMessageReceived.connect(function (msg) { root.handle(msg) })
        }
        onErrorStringChanged: console.warn("lyrics websocket:", server.errorString)
    }

    function handle(msg) {
        let m
        try { m = JSON.parse(msg) } catch (e) { return }
        if (m.type === "track") {
            console.log("lyrics track:", m.artist, "-", m.title, "| source:", m.source, "| lines:", (m.lines || []).length, "| colors:", JSON.stringify(m.colors || null))
            title = m.title || ""
            artist = m.artist || ""
            const c = m.colors
            if (dynamicColor && c && c.primary) {
                liveAccent = c.primary
                liveAccent2 = c.secondary || Qt.lighter(c.primary, 1.4)
            } else {
                liveAccent = accent
                liveAccent2 = Qt.lighter(accent, 1.4)
            }
            win.slotA = -1
            win.slotB = -1
            lineIdx = -1
            wordIdx = -1
            // drop double quotes (straight and curly) from the words
            const ls = m.lines || []
            for (const l of ls) {
                for (const w of l.words) w.text = w.text.replace(/["\u201C\u201D\u201E\u201F\u00AB\u00BB]/g, "")
                l.words = l.words.filter(w => w.text.trim() !== "")
            }
            lines = ls.filter(l => l.words.length > 0)
            interlude = false
            gapIntro = true
            gapAge = 0
            gapProgress = -1
            energyBase = energy          // new song → new baseline
            hitTimes = []
            trackStartMs = Date.now()
        } else if (m.type === "state") {
            basePos = m.position
            baseClock = Date.now()
            playing = m.playing
        }
    }

    function tick() {
        now = (playing ? basePos + (Date.now() - baseClock) : basePos) + offsetMs
        let li = -1
        for (let i = lines.length - 1; i >= 0; i--) {
            if (lines[i].t <= now) { li = i; break }
        }
        // gap around `now`: from the end of the last started line to the start of the next
        const gs = li >= 0 ? lines[li].end : 0
        const ge = li + 1 < lines.length ? lines[li + 1].t : -1
        gapIntro = li < 0
        if (li >= 0 && now >= lines[li].end) li = -1
        gapAge = now - gs
        gapProgress = ge < 0 ? -1 : Math.max(0, Math.min(1, (now - gs) / Math.max(1, ge - gs)))
        // starts a moment into the gap and ends a moment before the next line
        // (up to 1.2 s / 1.5 s, less in short gaps)
        const gl = ge < 0 ? 1e9 : ge - gs
        interlude = li < 0 && gl >= interludeMinMs
            && now - gs >= Math.min(1200, gl * 0.15) && (ge < 0 || ge - now >= Math.min(1500, gl * 0.2))
        let wi = -1
        if (li >= 0) {
            const ws = lines[li].words
            for (let k = ws.length - 1; k >= 0; k--) {
                if (ws[k].t <= now) { wi = k; break }
            }
        }
        lineIdx = li
        wordIdx = wi
    }

    // Two clocks, both computing the position from wall time (so running both is harmless):
    //  • Timer: always advances, even when nothing is being drawn (a FrameAnimation alone
    //    stalls in quiet gaps because the compositor stops requesting frames).
    //  • FrameAnimation: extra updates in sync with the display (144 Hz on eDP-1) while drawing.
    Timer {
        interval: 16
        repeat: true
        running: (root.lyricsOn || root.fullscreen) && root.lines.length > 0
        onTriggered: root.tick()
    }
    FrameAnimation {
        running: (root.lyricsOn || root.fullscreen) && root.lines.length > 0
        onTriggered: root.tick()
    }

    PanelWindow {
        id: win
        visible: root.lyricsOn || root.fullscreen
        // screen: Quickshell.screens[0]   // uncomment to pin to a monitor
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        // Fullscreen: on-demand focus (NOT exclusive — that would lock the keyboard on every
        // monitor). A focus grab gives us the keyboard on open so Esc works right away; clicking
        // a window on another monitor releases it. Otherwise never take focus.
        WlrLayershell.keyboardFocus: root.fullscreen ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
        // Overlay: end4-pC's wallpaper sits on the Bottom layer and would cover us there.
        // Click-through, so it never blocks windows.
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "lyrics-constellation"
        mask: root.fullscreen ? null : clickThrough   // click-through unless fullscreen
        Region { id: clickThrough }

        // ───────── fullscreen background (Esc to exit) ─────────
        Rectangle {
            id: fsBg
            anchors.fill: parent
            opacity: root.fullscreen ? 1 : 0
            visible: opacity > 0.01
            Behavior on opacity { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.darker(root.liveAccent, 5.5) }
                GradientStop { position: 0.55; color: "#07050c" }
                GradientStop { position: 1.0; color: Qt.darker(root.liveAccent, 4.5) }
            }

            focus: root.fullscreen
            Keys.onEscapePressed: root.fullscreen = false

            // ── immersive layers (fullscreen only) ──
            // 1. blurred, darkened album cover
            Image {
                id: coverImg
                anchors.fill: parent
                source: root.immersive ? root.coverArt : ""
                sourceSize: Qt.size(512, 512)   // higher res → smoother blur, less banding
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                visible: false
            }
            MultiEffect {
                anchors.fill: parent
                source: coverImg
                visible: root.immersive && root.fullscreen
                opacity: coverImg.status === Image.Ready ? 0.9 : 0
                Behavior on opacity { NumberAnimation { duration: 900 } }
                blurEnabled: true
                blur: 1.0
                blurMax: 64
                brightness: -0.52 + 0.14 * root.mood
                saturation: -0.1 + 0.5 * root.mood
            }

            // 2. ambient light in the song colour, breathing with loudness + beats
            Shape {
                anchors.fill: parent
                visible: root.immersive && root.fullscreen
                // kept soft so the word glow stands out; in a mid-song break it pulses hard with the beat
                opacity: Math.min(0.65 + 0.35 * root.breakK,
                    (0.2 + root.energy * 0.7 + root.beat * 0.15) * (0.45 + 0.55 * root.dyn) * (0.6 + 0.55 * root.mood)
                    + root.breakK * (0.12 + root.beat * 0.55))
                ShapePath {
                    strokeColor: "transparent"
                    fillGradient: RadialGradient {
                        centerX: fsBg.width / 2; centerY: fsBg.height * 0.48
                        focalX: centerX; focalY: centerY
                        centerRadius: fsBg.height * 0.75
                        GradientStop { position: 0.0; color: Qt.alpha(root.liveAccent, 0.32 + 0.3 * root.breakK) }
                        GradientStop { position: 0.5; color: Qt.alpha(root.liveAccent, 0.10 + 0.14 * root.breakK) }
                        GradientStop { position: 1.0; color: "transparent" }
                    }
                    PathRectangle { x: 0; y: 0; width: fsBg.width; height: fsBg.height }
                }
            }

            // 3. vignette so the lyrics stay readable
            Rectangle {
                anchors.fill: parent
                visible: root.immersive
                gradient: Gradient {
                    GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.55) }
                    GradientStop { position: 0.35; color: Qt.rgba(0, 0, 0, 0.1) }
                    GradientStop { position: 0.7; color: Qt.rgba(0, 0, 0, 0.1) }
                    GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.65) }
                }
            }

            // 4. starfield that moves with the music: pushed out on beats, swirls when loud,
            //    denser in loud parts, flashes on beats. Strength: `particleReact`.
            ParticleSystem {
                id: stars
                anchors.fill: parent
                running: root.immersive && root.fullscreen
            }
            ImageParticle {
                system: stars
                source: "qrc:///particleresources/glowdot.png"
                color: root.liveAccent
                colorVariation: 0.15
                alpha: 0.55
                alphaVariation: 0.35
                entryEffect: ImageParticle.Fade
                opacity: 0.7 + root.beat * 0.3 * root.pReact   // flash on beats
            }
            Emitter {            // slow ambient drift
                system: stars
                anchors.fill: parent
                // instrumental breaks: the starfield takes over
                emitRate: (8 + Math.min(1, root.energy * 1.6) * 24 * root.pReact) * (root.cardOn ? 2 : 1 + root.breakK)
                lifeSpan: 9000
                lifeSpanVariation: 3000
                size: 7
                sizeVariation: 6
                velocity: AngleDirection { angleVariation: 360; magnitude: 6; magnitudeVariation: 5 }
            }
            Emitter {            // beat bursts from around the centre
                id: burstEmitter
                system: stars
                x: parent.width * 0.2; y: parent.height * 0.25
                width: parent.width * 0.6; height: parent.height * 0.5
                emitRate: 0
                lifeSpan: 2200
                lifeSpanVariation: 800
                size: 10
                sizeVariation: 8
                velocity: AngleDirection { angleVariation: 360; magnitude: 70; magnitudeVariation: 50 }
            }
            Connections {
                target: root
                enabled: root.immersive && root.fullscreen
                function onBeatHit() { if (root.dyn > 0.55) burstEmitter.burst(Math.round(6 * root.dyn)) }
            }
            // beat push: repels every star from the centre, harder on stronger beats
            Attractor {
                system: stars
                anchors.fill: parent
                pointX: width / 2; pointY: height / 2
                affectedParameter: Attractor.Velocity
                proportionalToDistance: Attractor.Constant
                strength: -root.beat * root.beat * 320 * root.pReact
            }
            // swirl: random wandering that gets livelier with loudness
            Wander {
                system: stars
                anchors.fill: parent
                affectedParameter: Wander.Velocity
                xVariance: 6 + root.energy * 45 * root.pReact
                yVariance: 6 + root.energy * 45 * root.pReact
                pace: 30 + root.energy * 260 * root.pReact
            }
            // settle back to a calm drift after each push
            Friction {
                system: stars
                anchors.fill: parent
                factor: 1.4
                threshold: 10
            }

            Column {
                anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 56 }
                spacing: 4
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: root.title
                    opacity: root.cardOn ? 0 : 1          // the title card shows it instead
                    Behavior on opacity { NumberAnimation { duration: 700 } }
                    color: Qt.rgba(1, 1, 1, 0.55)
                    font.family: root.fontFamily
                    font.pixelSize: 20
                    font.weight: Font.DemiBold
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: root.artist
                    opacity: root.cardOn ? 0 : 1
                    Behavior on opacity { NumberAnimation { duration: 700 } }
                    color: Qt.rgba(1, 1, 1, 0.3)
                    font.family: root.fontFamily
                    font.pixelSize: 14
                }
                Text {           // hint: shown on entering fullscreen / moving the mouse, then fades
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Esc to exit"
                    color: Qt.rgba(1, 1, 1, 0.3)
                    font.family: root.fontFamily
                    font.pixelSize: 13
                    opacity: win.idle ? 0 : 1
                    Behavior on opacity { NumberAnimation { duration: 600 } }
                }
            }

            MouseArea {           // swallow clicks so nothing passes to windows underneath
                anchors.fill: parent
                enabled: root.fullscreen
                hoverEnabled: true
                cursorShape: win.idle ? Qt.BlankCursor : Qt.ArrowCursor   // hide the cursor when idle
                onPositionChanged: win.wake()
                onPressed: { win.wake(); fsBg.forceActiveFocus() }   // clicking the lyrics takes the keyboard back
            }
        }
        onVisibleChanged: if (visible && root.fullscreen) fsBg.forceActiveFocus()
        Connections {
            target: root
            function onFullscreenChanged() {
                fsGrab.active = root.fullscreen
                if (root.fullscreen) win.wake()
                if (root.fullscreen) fsBg.forceActiveFocus()
            }
        }
        // keyboard to the lyrics when fullscreen opens; released by clicking another window
        // (lyrics stay fullscreen on their monitor, other monitors work normally)
        HyprlandFocusGrab {
            id: fsGrab
            windows: [win]
            active: false
        }

        // fullscreen idle state: no mouse movement for `idleHideMs` → hide cursor and hint
        property bool idle: false
        function wake() { idle = false; idleTimer.restart() }
        Timer { id: idleTimer; interval: root.idleHideMs; onTriggered: win.idle = true }

        // two slots so the old constellation fades out while the new one fades in
        property int slotA: -1
        property int slotB: -1
        property bool useA: true

        Connections {
            target: root
            function onLineIdxChanged() {
                const li = root.lineIdx
                if (li < 0 || win.slotA === li || win.slotB === li) return
                if (win.useA) win.slotA = li; else win.slotB = li
                win.useA = !win.useA
            }
        }

        Constellation {
            anchors.fill: parent
            line: win.slotA >= 0 && win.slotA < root.lines.length ? root.lines[win.slotA] : null
            shown: root.lineIdx >= 0 && root.lineIdx === win.slotA
            wordIdx: shown ? root.wordIdx : (line ? line.words.length - 1 : -1)
            now: root.now
            dimmed: !root.playing
            accent: root.liveAccent
            fontFamily: root.fontFamily
            fontSize: root.fontSize
            beat: root.pulse
            energy: root.energy
            beatPulse: root.beatPulse * root.dyn * (0.3 + root.mood)
            mood: root.mood
            ghost: root.ghostStars
        }
        Constellation {
            anchors.fill: parent
            line: win.slotB >= 0 && win.slotB < root.lines.length ? root.lines[win.slotB] : null
            shown: root.lineIdx >= 0 && root.lineIdx === win.slotB
            wordIdx: shown ? root.wordIdx : (line ? line.words.length - 1 : -1)
            now: root.now
            dimmed: !root.playing
            accent: root.liveAccent
            fontFamily: root.fontFamily
            fontSize: root.fontSize
            beat: root.pulse
            energy: root.energy
            beatPulse: root.beatPulse * root.dyn * (0.3 + root.mood)
            mood: root.mood
            ghost: root.ghostStars
        }

        // ───────── title card for instrumental breaks ─────────
        Column {
            id: card
            anchors.centerIn: parent
            width: parent.width * 0.8
            spacing: root.fontSize * 0.14
            opacity: root.cardOn ? (root.playing ? 1 : 0.45) : 0
            visible: opacity > 0.01
            scale: (root.cardOn ? 1 : 0.94) + root.pulse * 0.02 * root.dyn    // breathes with the beat
            Behavior on opacity { NumberAnimation { duration: 900; easing.type: Easing.InOutQuad } }
            Behavior on scale { NumberAnimation { duration: 120 } }

            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: root.title
                color: "white"
                font.family: root.fontFamily
                font.pixelSize: Math.round(root.fontSize * 0.6)
                font.weight: Font.DemiBold
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
                renderType: Text.CurveRendering
                layer.enabled: true
                layer.effect: MultiEffect {
                    shadowEnabled: true
                    shadowColor: root.liveAccent
                    shadowBlur: 1.0
                    blurMax: 48 + 40 * root.breakK * root.beat
                    shadowOpacity: 0.9
                    brightness: root.breakK * root.beat * 0.25
                    shadowHorizontalOffset: 0
                    shadowVerticalOffset: 0
                }
            }
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: root.artist
                color: Qt.rgba(1, 1, 1, 0.6)
                font.family: root.fontFamily
                font.pixelSize: Math.round(root.fontSize * 0.26)
                elide: Text.ElideRight
                renderType: Text.CurveRendering
            }
            // thin line that fills as the first lyric approaches
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: root.fontSize * 2.2
                height: 2
                radius: 1
                color: Qt.rgba(1, 1, 1, 0.14)
                // only before the first line; mid-song breaks have no bar
                opacity: root.gapIntro && root.gapProgress >= 0 && root.lines.length > 0 ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 500 } }
                Rectangle {
                    height: parent.height
                    radius: 1
                    width: parent.width * Math.max(0, root.gapProgress)
                    color: root.liveAccent2
                }
            }
        }

        // ───────── running border: light that travels around the screen edge ─────────
        Shape {
            id: runner
            anchors.fill: parent
            visible: root.runningBorder && opacity > 0.01
            opacity: root.playing ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 800 } }

            // soft glow in the song colour around the running streaks
            layer.enabled: root.borderGlow > 0
            layer.samples: 4                       // 4× MSAA: smooth rounded corners
            layer.effect: MultiEffect {
                shadowEnabled: true
                shadowColor: root.liveAccent
                // glow flashes brighter on each beat
                shadowOpacity: root.beatBorder ? Math.min(1, 0.65 + root.beat * 0.5) : 1.0
                shadowBlur: 1.0
                blurMax: root.borderGlow
                shadowScale: root.beatBorder ? 1.0 + root.beat * 0.012 : 1.0
                shadowHorizontalOffset: 0
                shadowVerticalOffset: 0
                brightness: (root.beatBorder ? 0.1 + root.beat * 0.35 : 0.15) + root.breakK * root.beat * 0.4
            }

            readonly property real bw: root.borderWidth
            readonly property real r: 22          // matches the rounded screen corners
            readonly property color base: Qt.alpha(root.liveAccent, 0)   // nothing between the streaks
            property real angle: 0
            // clockwise; with beatBorder it runs faster in loud parts, slower in quiet ones
            FrameAnimation {
                running: runner.visible
                onTriggered: {
                    const k = (root.beatBorder ? 0.5 + Math.min(1.5, root.energy * 2.2) : 1) * (0.55 + 0.65 * root.mood)
                    runner.angle = (runner.angle - frameTime * 360000 / root.borderSpeedMs * k) % 360
                }
            }

            ShapePath {
                strokeColor: "transparent"
                strokeWidth: 0
                fillRule: ShapePath.OddEvenFill    // outer rect minus inner rect = frame
                fillGradient: ConicalGradient {
                    centerX: runner.width / 2
                    centerY: runner.height / 2
                    angle: runner.angle
                    // two comets on opposite sides, each a fading tail + bright head
                    GradientStop { position: 0.00; color: runner.base }
                    GradientStop { position: 0.17; color: runner.base }
                    GradientStop { position: 0.30; color: root.liveAccent }
                    GradientStop { position: 0.31; color: root.liveAccent }
                    GradientStop { position: 0.32; color: runner.base }
                    GradientStop { position: 0.67; color: runner.base }
                    GradientStop { position: 0.80; color: root.liveAccent }
                    GradientStop { position: 0.81; color: root.liveAccent }
                    GradientStop { position: 0.82; color: runner.base }
                    GradientStop { position: 1.00; color: runner.base }
                }
                PathRectangle {
                    x: 0; y: 0; width: runner.width; height: runner.height
                    radius: runner.r
                }
                PathRectangle {
                    x: runner.bw; y: runner.bw
                    width: runner.width - 2 * runner.bw; height: runner.height - 2 * runner.bw
                    radius: Math.max(0, runner.r - runner.bw)
                }
            }
        }
    }

    // ───────── ambient light on the other monitors (fullscreen only) ─────────
    // Peripheral colour makes the scene feel bigger. Click-through, never takes focus;
    // only the edges glow, so windows on those monitors stay usable.
    Variants {
        model: root.ambientMonitors ? Quickshell.screens.filter(s => s.name !== win.screen?.name) : []
        PanelWindow {
            id: amb
            required property var modelData
            screen: modelData
            visible: root.fullscreen
            anchors { top: true; bottom: true; left: true; right: true }
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            WlrLayershell.namespace: "lyrics-ambient"
            mask: Region {}

            Shape {
                id: glow
                anchors.fill: parent
                // breathes slowly with loudness, opens up when the song lifts, fades out on pause
                opacity: root.fullscreen && root.playing
                    ? Math.min(1, (0.35 + root.energy * 0.8) * (0.45 + 0.55 * root.dyn)) : 0
                // slow only: fast changes in peripheral vision pull attention away
                Behavior on opacity { NumberAnimation { duration: 1800; easing.type: Easing.InOutSine } }
                ShapePath {
                    strokeColor: "transparent"
                    fillGradient: RadialGradient {
                        centerX: glow.width / 2; centerY: glow.height / 2
                        focalX: centerX; focalY: centerY
                        centerRadius: Math.hypot(glow.width, glow.height) / 2
                        GradientStop { position: 0.0; color: "transparent" }
                        GradientStop { position: 0.62; color: "transparent" }
                        GradientStop { position: 0.85; color: Qt.alpha(root.liveAccent, 0.16) }
                        GradientStop { position: 1.0; color: Qt.alpha(root.liveAccent, 0.5) }
                    }
                    PathRectangle { x: 0; y: 0; width: glow.width; height: glow.height }
                }
            }
        }
    }
}
