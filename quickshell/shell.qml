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
    readonly property bool anyPlayer: true        // also follow other players (YouTube Music, browsers, mpv…) over MPRIS

    // ───────── sources ─────────
    // "bridge": the Spicetify extension sends lyrics, colours and position (Spotify).
    // "mpris":  any other player. Track and position come from MPRIS, lyrics from LRCLIB,
    //           colours from the cover image. Spotify without the extension works this way too.
    // The bridge wins while Spotify is playing; otherwise whichever player is playing.
    function isSpotify(p) {
        return (p.dbusName || "").toLowerCase().includes("spotify")
            || (p.identity || "").toLowerCase().includes("spotify")
    }
    readonly property var spotifyPlayer: Mpris.players.values.find(p => isSpotify(p)) ?? null
    property string owner: "bridge"
    property var mp: null               // the MPRIS player followed when owner is "mpris"
    property int bridgeClients: 0
    property bool bridgePlaying: false
    property var bridgeTrack: null
    property real bridgePos: 0
    property real bridgeClock: 0
    property string mpKey: ""           // identifies the MPRIS track whose lyrics are loaded
    property string lyricSource: "none"
    // Credit for the lyrics on screen: { text, links: [{ name, url }] }. Required by the
    // Spicy Lyrics API terms, and shown for the other sources too.
    property var credit: null

    // Spicy Lyrics API key (optional): word-synced lyrics for any player. Read from the
    // environment or from ~/.config/asterism/spicy-lyrics.secret. Never logged.
    property string spicyKey: (Quickshell.env("SPICY_LYRICS_SECRET_KEY") || "").trim()
    property var spicyMemo: ({})        // Spotify track id → converted lyrics, for this session
    FileView {
        path: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/asterism/spicy-lyrics.secret"
        printErrors: false
        onLoaded: { const k = text().trim(); if (k) root.spicyKey = k }
    }
    readonly property real startedMs: Date.now()

    // album cover from MPRIS
    // A browser tab can show up as two players (the browser itself and plasma-browser-integration)
    // and often only one of them reports the cover, so borrow it from the twin when ours has none.
    readonly property string mprisArt: {
        if (!mp) return ""
        if (mp.trackArtUrl) return mp.trackArtUrl
        const mine = cleanTitle(mp.trackTitle || "").toLowerCase()
        if (!mine) return ""
        for (const p of Mpris.players.values) {
            if (p === mp || !p.trackArtUrl || isSpotify(p)) continue
            const t = cleanTitle(p.trackTitle || "").toLowerCase()
            if (t && (t === mine || t.includes(mine) || mine.includes(t))) return p.trackArtUrl
        }
        return ""
    }
    readonly property string coverArt: owner === "mpris" ? mprisArt : (spotifyPlayer?.trackArtUrl ?? "")
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
        function source(): string {
            return root.owner + (root.owner === "mpris" && root.mp ? " (" + (root.mp.identity || root.mp.dbusName) + ")" : "")
                + " | " + root.artist + " - " + root.title + " | lyrics: " + root.lyricSource + " | lines: " + root.lines.length
                + " | extension clients: " + root.bridgeClients + " | Spicy Lyrics key: " + (root.spicyKey ? "yes" : "no")
        }
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
            root.bridgeClients++
            sock.onTextMessageReceived.connect(function (msg) { root.handle(msg) })
            sock.onStatusChanged.connect(function (st) {
                if (st !== WebSocket.Closed) return
                root.bridgeClients = Math.max(0, root.bridgeClients - 1)
                if (root.bridgeClients === 0) root.bridgePlaying = false
            })
        }
        onErrorStringChanged: console.warn("lyrics websocket:", server.errorString)
    }

    function handle(msg) {
        let m
        try { m = JSON.parse(msg) } catch (e) { return }
        if (m.type === "track") {
            bridgeTrack = m
            if (owner === "bridge") applyTrack(m)
            // no word timing from the extension → ask the Spicy Lyrics API by track id
            if (spicyKey && m.source !== "spicy-syllable" && /^[A-Za-z0-9]{22}$/.test(m.id || "")) {
                spicyById(m.id, function (r) {
                    if (!r || root.bridgeTrack !== m) return
                    if (r.type !== "Syllable" && m.source !== "none") return   // only a real improvement
                    const up = { type: "track", id: m.id, title: m.title, artist: m.artist, colors: m.colors,
                                 source: r.sourceName, credit: r.credit, lines: r.lines }
                    root.bridgeTrack = up
                    if (root.owner === "bridge") root.applyTrack(up, true)
                })
            }
        } else if (m.type === "state") {
            bridgePos = m.position
            bridgeClock = Date.now()
            bridgePlaying = m.playing
            if (m.playing && owner !== "bridge") {        // Spotify started: the bridge takes over
                owner = "bridge"
                mpKey = ""
                if (bridgeTrack) applyTrack(bridgeTrack)
            }
            if (owner === "bridge") {
                basePos = m.position
                baseClock = bridgeClock
                playing = m.playing
            }
        }
    }

    // Show a track: { title, artist, source, colors, lines }. `keepPulse` = same song, lyrics just arrived.
    function applyTrack(m, keepPulse) {
        console.log("lyrics track:", m.artist, "-", m.title, "| source:", m.source, "| lines:", (m.lines || []).length, "| colors:", JSON.stringify(m.colors || null))
        title = m.title || ""
        artist = m.artist || ""
        lyricSource = m.source || "none"
        credit = (m.lines || []).length === 0 ? null
            : m.credit ? m.credit
            : lyricSource.startsWith("spicy") ? { text: "Lyrics: Spicy Lyrics", links: [] }
            : lyricSource === "spotify" ? { text: "Lyrics: Spotify", links: [] }
            : lyricSource === "lrclib" ? { text: "Lyrics: LRCLIB", links: [] } : null
        if (m.colors !== undefined) setColors(m.colors)
        win.slotA = -1
        win.slotB = -1
        lineIdx = -1
        wordIdx = -1
        // drop double quotes (straight and curly) from the words
        const ls = m.lines || []
        for (const l of ls) {
            for (const w of l.words) w.text = w.text.replace(/["“”„‟«»]/g, "")
            l.words = l.words.filter(w => w.text.trim() !== "")
        }
        lines = ls.filter(l => l.words.length > 0)
        interlude = false
        gapIntro = true
        gapAge = 0
        gapProgress = -1
        if (keepPulse) return
        energyBase = energy          // new song → new baseline
        hitTimes = []
        trackStartMs = Date.now()
    }

    function setColors(c) {
        if (dynamicColor && c && c.primary) {
            liveAccent = c.primary
            liveAccent2 = c.secondary || Qt.lighter(c.primary, 1.4)
        } else {
            liveAccent = accent
            liveAccent2 = Qt.lighter(accent, 1.4)
        }
    }

    // ───────── any player over MPRIS ─────────
    // Runs twice a second: picks the player to follow, notices track changes, syncs the position.
    Timer {
        interval: 500; repeat: true; triggeredOnStart: true
        running: root.anyPlayer
        onTriggered: root.pollMpris()
    }

    function pollMpris() {
        // just started: give the extension a few seconds to reconnect before treating Spotify as "any player"
        const bridgeUp = bridgeClients > 0 || Date.now() - startedMs < 6000
        // Spotify is the bridge's job while the extension is connected
        const cand = Mpris.players.values.filter(p => !(bridgeUp && isSpotify(p)))
        if (!(bridgeUp && bridgePlaying)) {
            // a browser tab can appear as two players; prefer the one that reports a cover
            const p = cand.find(x => x.isPlaying && x.trackArtUrl) ?? cand.find(x => x.isPlaying) ?? null
            if (p && (owner !== "mpris" || mp !== p) && !(owner === "mpris" && mp && mp.isPlaying)) {
                if (owner !== "mpris") mpKey = ""
                owner = "mpris"
                mp = p
            }
        }
        if (owner !== "mpris") return
        if (!mp || !Mpris.players.values.includes(mp)) {      // player closed
            mp = null
            playing = false
            if (bridgeUp && bridgeTrack) { owner = "bridge"; applyTrack(bridgeTrack); basePos = bridgePos; baseClock = Date.now() }
            return
        }
        // cleaned title only: the twin player of a browser tab names the same song differently
        const key = cleanTitle(mp.trackTitle || "").toLowerCase()
        if (key !== mpKey && (mp.trackTitle || "") !== "") {
            mpKey = key
            mprisTrack(key)
        }
        // Quickshell extrapolates `position` (seconds) from the player's last report
        basePos = (mp.positionSupported ? mp.position : 0) * 1000
        baseClock = Date.now()
        playing = mp.isPlaying
    }

    // Titles from video sites carry noise: "Artist - Song (Official Video)", "Artist - Topic".
    function cleanTitle(t) {
        return t.replace(/\s*[\(\[][^\)\]]*(official|video|audio|lyric|visuali[sz]er|\bmv\b|\bhd\b|\b4k\b|explicit)[^\)\]]*[\)\]]/ig, "")
                .replace(/\s+[-–—|]\s+YouTube(\s+Music)?$/i, "")     // browser tab titles end with the site name
                .replace(/\s*\|.*$/, "").trim()
    }
    function cleanArtist(a) {
        return a.replace(/\s*-\s*Topic$/i, "").replace(/VEVO$/i, "").trim()
    }

    function mprisTrack(key) {
        const rawTitle = mp.trackTitle || ""
        const rawArtist = mp.trackArtist || ""
        const album = mp.trackAlbum || ""
        const dur = mp.lengthSupported && mp.length > 0 && mp.length < 86400 ? mp.length : 0   // seconds
        let t = cleanTitle(rawTitle)
        const a = cleanArtist(rawArtist)
        // "Artist - Song" where the artist is already known → keep just the song
        const pre = t.match(/^(.+?)\s+[-–—]\s+(.+)$/)
        if (pre && a !== "" && pre[1].toLowerCase() === a.toLowerCase()) t = pre[2]
        // what to ask LRCLIB for, best guess first
        const tries = [{ title: t, artist: a }]
        const sp = t.match(/^(.+?)\s+[-–—]\s+(.+)$/)   // "Artist - Song" in the title
        const parts = sp ? [sp[1], sp[2]] : [t]
        if (sp) {
            const alt = [{ title: parts[1], artist: parts[0] }, { title: parts[0], artist: parts[1] }]
            if (a === "") { tries.length = 0; tries.push(alt[0], alt[1], { title: t, artist: "" }) }   // no artist reported: the split is the best guess
            else tries.push(alt[0], alt[1])
        }
        const shown = sp && (a === "" || rawArtist !== a) ? { title: parts[1], artist: parts[0] } : { title: t, artist: a }
        applyTrack({ title: shown.title, artist: shown.artist, source: "none", colors: undefined, lines: [] })
        coverSampler.sample()
        const viaLrclib = function () {
            lrclib(tries, 0, album, dur, function (raw, hit) {
                if (root.mpKey !== key || root.owner !== "mpris") return     // another song by now
                if (raw && raw.length) {
                    applyTrack({ title: hit.title, artist: hit.artist, source: "lrclib", colors: undefined,
                                 lines: buildLines(raw, dur * 1000) }, true)
                } else if (root.spicyKey && dur > 0) {
                    // Last resort: the album version from Spicy Lyrics, ignoring the length. A video
                    // with an intro is longer than the song, so these can run early.
                    spicySearch(tries.slice(0, 2), 0, album, 0, true, function (r, q) {
                        if (!r || root.mpKey !== key || root.owner !== "mpris") return
                        applyTrack({ title: q.title, artist: q.artist, source: r.sourceName, credit: r.credit,
                                     colors: undefined, lines: r.lines }, true)
                    })
                }
            })
        }
        if (!spicyKey) { viaLrclib(); return }
        // With a Spicy Lyrics API key: word-synced lyrics first, LRCLIB if it has nothing.
        const got = function (r, q) {
            if (root.mpKey !== key || root.owner !== "mpris") return
            if (!r) { viaLrclib(); return }
            applyTrack({ title: q.title, artist: q.artist, source: r.sourceName, credit: r.credit,
                         colors: undefined, lines: r.lines }, true)
        }
        const sid = isSpotify(mp) ? String(mp.metadata["mpris:trackid"] || "").match(/([A-Za-z0-9]{22})$/) : null
        if (sid) spicyById(sid[1], r => got(r, shown))            // Spotify without the extension
        else spicySearch(tries.slice(0, 2), 0, album, dur, false, got)
    }

    // ───────── Spicy Lyrics API (developers.spicylyrics.org) ─────────
    function spicyGet(path, cb) {
        const x = new XMLHttpRequest()
        x.onreadystatechange = function () {
            if (x.readyState !== XMLHttpRequest.DONE) return
            let j = null
            if (x.status === 200) { try { j = JSON.parse(x.responseText) } catch (e) {} }
            if (x.status !== 200 && x.status !== 404) console.warn("lyrics: Spicy Lyrics API answered", x.status)
            cb(j && j.Body ? j.Body : null)
        }
        x.open("GET", "https://api.spicylyrics.org" + path)
        x.setRequestHeader("Authorization", "Bearer " + spicyKey)
        x.send()
    }

    // Lyrics for a Spotify track id → { lines, type, sourceName, credit } or null
    function spicyById(id, cb) {
        if (spicyMemo[id] !== undefined) { cb(spicyMemo[id]); return }
        spicyGet("/v1/lyrics/" + id, function (b) {
            const lines = b ? fromSpicy(b, (b.EndTime || 0) * 1000) : null
            const r = lines ? { lines: lines, type: b.Type, credit: spicyCredit(b),
                                sourceName: b.Type === "Syllable" ? "spicy-syllable" : "spicy-line" } : null
            spicyMemo[id] = r
            cb(r)
        })
    }

    // Find the track by title, then fetch its lyrics. Only matches the API itself trusts.
    function spicySearch(tries, i, album, dur, exactOnly, cb) {
        if (i >= tries.length) { cb(null, null); return }
        const q = tries[i]
        if (!q.title) { spicySearch(tries, i + 1, album, dur, exactOnly, cb); return }
        const e = encodeURIComponent
        spicyGet("/v1/tracks/search?limit=3&title=" + e(q.title) + (q.artist ? "&artist=" + e(q.artist) : "")
                 + (album ? "&album=" + e(album) : "") + (dur > 0 ? "&duration=" + dur.toFixed(3) : ""), function (b) {
            const hit = b && Array.isArray(b.results) ? b.results[0] : null
            // "exact" is safe; "likely" only when we named an artist (a slightly different length)
            if (!hit || !(hit.tier === "exact" || (hit.tier === "likely" && q.artist && !exactOnly))) { spicySearch(tries, i + 1, album, dur, exactOnly, cb); return }
            spicyById(hit.id, function (r) {
                if (r) cb(r, { title: hit.title || q.title, artist: (hit.artists || []).join(", ") || q.artist })
                else spicySearch(tries, i + 1, album, dur, exactOnly, cb)
            })
        })
    }

    // The API's terms: always name the provider; for community syncs also credit the uploader and the maker.
    function spicyCredit(b) {
        if (b.source === "apple_music") return { text: "Lyrics: Apple Music, via Spicy Lyrics", links: [] }
        if (b.source === "spotify") return { text: "Lyrics: Spotify, via Spicy Lyrics", links: [] }
        if (b.source !== "spicy_lyrics") return { text: "Lyrics via Spicy Lyrics", links: [] }
        const a = b.UploadAttribution || {}
        const links = []
        if (a.Maker && a.Maker.username) links.push({ label: "synced by", name: a.Maker.username, url: a.Maker.url || "" })
        if (a.Uploader && a.Uploader.username) links.push({ label: "uploaded by", name: a.Uploader.username, url: a.Uploader.url || "" })
        return { text: "Lyrics: Spicy Lyrics", links: links }
    }

    // Spicy Lyrics content → our { t, end, words: [{ text, t }] } lines (same as the extension)
    function fromSpicy(c, duration) {
        const ms = x => Math.round(Number(x) * 1000)
        const clean = t => String(t === undefined || t === null ? "" : t).replace(/[\u200B\u200C\u200D\uFEFF]/g, "")
        if (c.Type === "Syllable" && Array.isArray(c.Content)) {
            const out = []
            for (const g of c.Content) {
                const lead = g ? g.Lead : null
                if (!lead || !Array.isArray(lead.Syllables)) continue
                const words = []
                let cur = null
                for (const sy of lead.Syllables) {
                    if (!cur) cur = { text: "", t: ms(sy.StartTime) }
                    cur.text += clean(sy.Text)
                    if (!sy.IsPartOfWord) {            // syllables join until IsPartOfWord is false
                        if (cur.text.trim()) words.push({ text: cur.text.trim(), t: cur.t })
                        cur = null
                    }
                }
                if (cur && cur.text.trim()) words.push({ text: cur.text.trim(), t: cur.t })
                if (words.length) out.push({ t: ms(lead.StartTime), leadEnd: ms(lead.EndTime), words: words })
            }
            out.sort((x, y) => x.t - y.t)
            // keep each line up a little after its last word, but not past the next line
            for (let i = 0; i < out.length; i++) {
                const next = i + 1 < out.length ? out[i + 1].t : (duration || out[i].leadEnd + 4000)
                out[i].end = Math.max(out[i].leadEnd, Math.min(next, out[i].leadEnd + 1500))
            }
            return out.length ? out : null
        }
        if (c.Type === "Line" && Array.isArray(c.Content)) {
            const raw = c.Content.filter(l => l && l.Text != null && l.StartTime != null)
                .map(l => ({ t: ms(l.StartTime), text: clean(l.Text).trim() }))
                .sort((x, y) => x.t - y.t)
            const lines = buildLines(raw, duration)
            return lines.length ? lines : null
        }
        return null      // "Static": no timings
    }

    function httpJson(url, cb) {
        const x = new XMLHttpRequest()
        x.onreadystatechange = function () {
            if (x.readyState !== XMLHttpRequest.DONE) return
            let j = null
            if (x.status === 200) { try { j = JSON.parse(x.responseText) } catch (e) {} }
            cb(j)
        }
        x.open("GET", url)
        x.send()
    }

    // LRCLIB: exact match first (needs the duration), then a search; next guess if both miss.
    function lrclib(tries, i, album, dur, cb) {
        if (i >= tries.length) { cb(null, null); return }
        const q = tries[i]
        if (!q.title) { lrclib(tries, i + 1, album, dur, cb); return }
        const e = encodeURIComponent
        const search = function () {
            httpJson("https://lrclib.net/api/search?track_name=" + e(q.title) + (q.artist ? "&artist_name=" + e(q.artist) : ""), function (arr) {
                let best = null, bestD = 1e9
                for (const r of (Array.isArray(arr) ? arr : [])) {
                    if (!r.syncedLyrics) continue
                    const d = dur > 0 ? Math.abs((r.duration || 0) - dur) : 0
                    if (d < bestD) { best = r; bestD = d }
                }
                if (best && (dur <= 0 || bestD <= 8)) cb(parseLRC(best.syncedLyrics), q)
                else lrclib(tries, i + 1, album, dur, cb)
            })
        }
        if (dur > 0 && q.artist) {
            httpJson("https://lrclib.net/api/get?track_name=" + e(q.title) + "&artist_name=" + e(q.artist)
                     + "&album_name=" + e(album) + "&duration=" + Math.round(dur), function (j) {
                if (j && j.syncedLyrics) cb(parseLRC(j.syncedLyrics), q)
                else search()
            })
        } else search()
    }

    function parseLRC(lrc) {
        const out = []
        for (const raw of lrc.split("\n")) {
            const re = /\[(\d+):(\d+(?:\.\d+)?)\]/g
            const stamps = []
            let mm
            while ((mm = re.exec(raw)) !== null) stamps.push(mm)
            if (!stamps.length) continue
            const text = raw.replace(/\[[^\]]*\]/g, "").replace(/<[^>]*>/g, "").trim()
            for (const m of stamps) out.push({ t: (Number(m[1]) * 60 + Number(m[2])) * 1000, text: text })
        }
        return out.sort((x, y) => x.t - y.t)
    }

    // line timing → estimated word timing (same method as the Spicetify extension)
    function buildLines(ls, duration) {
        const out = []
        for (let i = 0; i < ls.length; i++) {
            const t = ls[i].t, text = ls[i].text
            if (!text || /^[♪♫\s]*$/.test(text)) continue
            let next = i + 1 < ls.length ? ls[i + 1].t : duration
            if (!(next > t)) next = t + 10000
            const words = text.split(/\s+/).filter(Boolean)
            const span = Math.min(next - t, words.length * 600 + 800) * 0.85
            const weights = words.map(w => w.length + 2)
            const total = weights.reduce((x, y) => x + y, 0)
            let acc = 0
            const ws = []
            for (let k = 0; k < words.length; k++) {
                ws.push({ text: words[k], t: Math.round(t + span * acc / total) })
                acc += weights[k]
            }
            out.push({ t: t, end: Math.min(next, t + span + 2500), words: ws })
        }
        return out
    }

    // Dominant vivid colour of the cover (same method as the extension): hue buckets weighted
    // by saturation and brightness, then lifted so it glows on a dark screen. null = greyscale.
    function coverColors(d) {
        const B = []
        for (let i = 0; i < 36; i++) B.push({ w: 0, h: 0, s: 0 })
        let any = false
        for (let i = 0; i < d.length; i += 4) {
            const r = d[i] / 255, g = d[i + 1] / 255, b = d[i + 2] / 255
            const max = Math.max(r, g, b), min = Math.min(r, g, b), c = max - min
            if (max < 0.15 || c < 0.08) continue
            const s = c / max
            let h = max === r ? ((g - b) / c) % 6 : max === g ? (b - r) / c + 2 : (r - g) / c + 4
            h = (h * 60 + 360) % 360
            const w = s * s * max
            const k = B[Math.min(35, Math.floor(h / 10))]
            k.w += w; k.h += h * w; k.s += s * w
            any = true
        }
        if (!any) return null
        let best = 0, bestW = -1
        for (let i = 0; i < 36; i++) {
            const w = B[i].w + 0.5 * (B[(i + 35) % 36].w + B[(i + 1) % 36].w)
            if (w > bestW) { bestW = w; best = i }
        }
        const k = B[best]
        const hue = k.h / k.w / 360
        const sat = Math.max(0.65, Math.min(1, k.s / k.w))
        const hx = c => "#" + [c.r, c.g, c.b].map(v => ("0" + Math.round(v * 255).toString(16)).slice(-2)).join("")
        return { primary: hx(Qt.hsla(hue, sat, 0.62, 1)), secondary: hx(Qt.hsla(hue, sat, 0.75, 1)),
                 dark: hx(Qt.hsla(hue, sat, 0.18, 1)), from: "cover" }
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

        // Reads the cover's pixels to pick the song colour for MPRIS players (the extension
        // does this itself for Spotify). Invisible; it only needs to live in a window to paint.
        Canvas {
            id: coverSampler
            width: 32; height: 32
            opacity: 0
            property string url: ""
            function sample() {
                const u = root.coverArt
                if (root.owner !== "mpris") return
                if (!u) { root.setColors(null); return }
                if (u === url && isImageLoaded(u)) { requestPaint(); return }
                if (url && url !== u) unloadImage(url)
                url = u
                if (isImageLoaded(u)) requestPaint(); else loadImage(u)
            }
            onImageLoaded: requestPaint()
            onPaint: {
                if (root.owner !== "mpris" || !url || url !== root.coverArt || !isImageLoaded(url)) return
                const ctx = getContext("2d")
                ctx.drawImage(url, 0, 0, width, height)
                const c = root.coverColors(ctx.getImageData(0, 0, width, height).data)
                console.log("lyrics cover colour:", JSON.stringify(c))
                root.setColors(c)
            }
            Connections {
                target: root
                function onCoverArtChanged() { coverSampler.sample() }   // art often arrives after the title
                function onOwnerChanged() { coverSampler.sample() }
            }
            Connections {
                target: win
                function onVisibleChanged() { if (win.visible) coverSampler.sample() }
            }
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

        // ───────── lyrics credit ─────────
        // Fullscreen: always there, small and quiet; names open the contributor's page.
        // Overlay: at the start of a song and after its last line (clicks pass through there).
        Text {
            id: creditLine
            anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 20 }
            readonly property bool on: root.credit !== null && root.lines.length > 0
                && (root.fullscreen || root.gapIntro || root.gapProgress < 0)
            function esc(t) { return String(t).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") }
            text: {
                const c = root.credit
                if (!c) return ""
                let t = esc(c.text)
                for (const l of (c.links || []))
                    t += " · " + esc(l.label) + " " + (l.url ? '<a href="' + esc(l.url).replace(/"/g, "&quot;") + '">' + esc(l.name) + "</a>" : esc(l.name))
                return t
            }
            textFormat: Text.StyledText
            linkColor: Qt.rgba(1, 1, 1, 0.75)
            onLinkActivated: link => Qt.openUrlExternally(link)
            color: Qt.rgba(1, 1, 1, 0.6)
            font.family: root.fontFamily
            font.pixelSize: 12
            opacity: on ? (root.fullscreen ? 0.55 : 0.8) : 0
            visible: opacity > 0.01
            Behavior on opacity { NumberAnimation { duration: 800 } }
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
