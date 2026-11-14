// lyrics-bridge.js — Spicetify extension
// Sends synced lyrics + playback position to the Quickshell "lyrics" overlay
// over a local WebSocket (ws://127.0.0.1:8975).
(async function lyricsBridge() {
  while (!Spicetify?.Player?.addEventListener || !Spicetify?.CosmosAsync || !Spicetify?.Player?.data) {
    await new Promise((r) => setTimeout(r, 300));
  }

  const PORT = 8975;
  let ws = null;
  let lastTrack = null;
  let reqId = 0;

  // ---------- connection to Quickshell ----------
  function connect() {
    try {
      ws = new WebSocket(`ws://127.0.0.1:${PORT}`);
    } catch (e) {
      setTimeout(connect, 3000);
      return;
    }
    ws.onopen = () => {
      if (lastTrack) send(lastTrack);
      sendState();
    };
    ws.onclose = () => {
      ws = null;
      setTimeout(connect, 3000); // Quickshell not running yet → keep retrying
    };
    ws.onerror = () => {};
  }

  function send(obj) {
    if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj));
  }

  function sendState() {
    send({
      type: "state",
      position: Spicetify.Player.getProgress(),
      playing: Spicetify.Player.isPlaying(),
    });
  }

  // ---------- lyrics sources ----------
  async function spotifyLyrics(id) {
    const res = await Spicetify.CosmosAsync.get(
      `https://spclient.wg.spotify.com/color-lyrics/v2/track/${id}?format=json&vocalRemoval=false&market=from_token`
    );
    const l = res?.lyrics;
    if (!l || l.syncType === "UNSYNCED" || !Array.isArray(l.lines)) return null;
    return l.lines.map((x) => ({ t: Number(x.startTimeMs), text: (x.words || "").trim() }));
  }

  function parseLRC(lrc) {
    const out = [];
    for (const raw of lrc.split("\n")) {
      const stamps = [...raw.matchAll(/\[(\d+):(\d+(?:\.\d+)?)\]/g)];
      if (!stamps.length) continue;
      const text = raw.replace(/\[[^\]]*\]/g, "").replace(/<[^>]*>/g, "").trim();
      for (const m of stamps) out.push({ t: (Number(m[1]) * 60 + Number(m[2])) * 1000, text });
    }
    return out.sort((a, b) => a.t - b.t);
  }

  async function lrclibLyrics(title, artist, album, durationMs) {
    const q = new URLSearchParams({
      track_name: title,
      artist_name: artist,
      album_name: album,
      duration: String(Math.round(durationMs / 1000)),
    });
    const r = await fetch(`https://lrclib.net/api/get?${q}`);
    if (r.ok) {
      const j = await r.json();
      if (j.syncedLyrics) return parseLRC(j.syncedLyrics);
    }
    // fuzzy fallback
    const s = await fetch(
      `https://lrclib.net/api/search?${new URLSearchParams({ track_name: title, artist_name: artist })}`
    );
    if (!s.ok) return null;
    const hit = (await s.json()).find((x) => x.syncedLyrics);
    return hit ? parseLRC(hit.syncedLyrics) : null;
  }

  // ---------- song colours (from album art) ----------
  // "spotify:image:abc" or "https://..." → https URL of the cover
  function coverUrl(item) {
    const m = item?.metadata ?? {};
    const raw =
      m.image_xlarge_url || m.image_large_url || m.image_url ||
      item?.images?.[0]?.url || item?.album?.images?.[0]?.url || "";
    if (raw.startsWith("spotify:image:")) return "https://i.scdn.co/image/" + raw.slice(14);
    return raw.startsWith("http") ? raw : null;
  }

  const hex = (r, g, b) => "#" + [r, g, b].map((x) => Math.round(x).toString(16).padStart(2, "0")).join("");

  function hslToRgb(h, s, l) {
    const k = (n) => (n + h / 30) % 12;
    const a = s * Math.min(l, 1 - l);
    const f = (n) => l - a * Math.max(-1, Math.min(k(n) - 3, Math.min(9 - k(n), 1)));
    return [f(0) * 255, f(8) * 255, f(4) * 255];
  }

  // Dominant vivid colour of the cover: hue buckets weighted by saturation & brightness,
  // then lifted so it glows well as a border on a dark screen.
  async function coverColors(url) {
    const img = new Image();
    img.crossOrigin = "anonymous";
    img.src = url;
    await img.decode();
    const N = 48;
    const cv = document.createElement("canvas");
    cv.width = cv.height = N;
    const ctx = cv.getContext("2d", { willReadFrequently: true });
    ctx.drawImage(img, 0, 0, N, N);
    const d = ctx.getImageData(0, 0, N, N).data;

    const B = Array.from({ length: 36 }, () => ({ w: 0, h: 0, s: 0 }));
    let any = false;
    for (let i = 0; i < d.length; i += 4) {
      const r = d[i] / 255, g = d[i + 1] / 255, b = d[i + 2] / 255;
      const max = Math.max(r, g, b), min = Math.min(r, g, b), c = max - min;
      if (max < 0.15 || c < 0.08) continue; // skip near-black & greys
      const s = c / max;
      let h = max === r ? ((g - b) / c) % 6 : max === g ? (b - r) / c + 2 : (r - g) / c + 4;
      h = (h * 60 + 360) % 360;
      const w = s * s * max; // favour vivid, bright pixels
      const k = B[Math.floor(h / 10)];
      k.w += w; k.h += h * w; k.s += s * w;
      any = true;
    }
    if (!any) return null; // greyscale cover → keep the default accent

    // best bucket together with its neighbours (hues straddle bucket edges)
    let best = 0, bestW = -1;
    for (let i = 0; i < 36; i++) {
      const w = B[i].w + 0.5 * (B[(i + 35) % 36].w + B[(i + 1) % 36].w);
      if (w > bestW) { bestW = w; best = i; }
    }
    const k = B[best];
    const hue = k.h / k.w;
    const sat = Math.max(0.65, Math.min(1, k.s / k.w));
    return {
      primary: hex(...hslToRgb(hue, sat, 0.62)),
      secondary: hex(...hslToRgb(hue, sat, 0.75)),
      dark: hex(...hslToRgb(hue, sat, 0.18)),
      from: "cover",
    };
  }

  async function songColors(item) {
    const url = coverUrl(item);
    if (url) {
      try {
        const c = await coverColors(url);
        if (c) return c;
      } catch (e) {
        console.warn("[lyrics-bridge] cover colour failed:", e);
      }
    }
    try {
      const c = await Spicetify.colorExtractor(item.uri);
      const ok = (x) => (typeof x === "string" && /^#[0-9a-f]{6}$/i.test(x) ? x : null);
      const primary = ok(c?.VIBRANT) || ok(c?.LIGHT_VIBRANT) || ok(c?.PROMINENT);
      const secondary = ok(c?.LIGHT_VIBRANT) || ok(c?.VIBRANT_NON_ALARMING) || ok(c?.PROMINENT);
      if (primary) return { primary, secondary: secondary || primary, dark: ok(c?.DARK_VIBRANT), from: "extractor" };
    } catch (e) {
      console.warn("[lyrics-bridge] colorExtractor failed:", e);
    }
    return null;
  }

  // ---------- line timing → word timing ----------
  // Spotify/LRCLIB are line-synced, so word times are estimated by
  // spreading each line's words across its duration (weighted by length).
  function build(lines, duration) {
    const out = [];
    for (let i = 0; i < lines.length; i++) {
      const { t, text } = lines[i];
      if (!text || /^[♪♫\s]*$/.test(text)) continue;
      let next = i + 1 < lines.length ? lines[i + 1].t : duration;
      if (!(next > t)) next = t + 10000;
      const words = text.split(/\s+/).filter(Boolean);
      const span = Math.min(next - t, words.length * 600 + 800) * 0.85;
      const weights = words.map((w) => w.length + 2);
      const total = weights.reduce((a, b) => a + b, 0);
      let acc = 0;
      out.push({
        t,
        end: Math.min(next, t + span + 2500),
        words: words.map((w, k) => {
          const wt = t + (span * acc) / total;
          acc += weights[k];
          return { text: w, t: Math.round(wt) };
        }),
      });
    }
    return out;
  }

  // ---------- Spicy Lyrics (if installed): reuse what it already downloaded ----------
  // Spicy Lyrics fetches lyrics on every song change and stores them in the page's
  // CacheStorage ("SpicyLyrics_LyricsStore_g1", key "/<trackId>", value
  // { ExpiresAt, CacheVersion, Content }). We only READ that local cache — no extra
  // requests to its servers. Most entries are word-synced ("Syllable"): real per-word
  // timing instead of our estimate. If the format changes, this just returns null.
  const SPICY_CACHE = "SpicyLyrics_LyricsStore_g1";

  async function spicyCached(id) {
    try {
      if (!("caches" in window) || !(await caches.has(SPICY_CACHE))) return null;
      const res = await (await caches.open(SPICY_CACHE)).match("/" + id);
      if (!res) return null;
      const d = await res.json();
      if (!d || typeof d !== "object" || (d.ExpiresAt && d.ExpiresAt < Date.now())) return null;
      const c = d.Content;
      return c && typeof c === "object" && typeof c.Type === "string" ? c : null;
    } catch (e) {
      return null;
    }
  }

  const ms = (s) => Math.round(Number(s) * 1000);
  const clean = (t) => String(t ?? "").replace(/[​‌‍﻿]/g, "");

  // Spicy Lyrics content → our { t, end, words: [{ text, t }] } lines
  function fromSpicy(c, duration) {
    if (c.Type === "Syllable" && Array.isArray(c.Content)) {
      const out = [];
      for (const g of c.Content) {
        const lead = g?.Lead;
        if (!Array.isArray(lead?.Syllables)) continue;
        const words = [];
        let cur = null;
        for (const s of lead.Syllables) {
          const text = clean(s?.Text);
          if (!cur) cur = { text: "", t: ms(s.StartTime) };
          cur.text += text;
          if (!s.IsPartOfWord) {                 // syllables join until IsPartOfWord is false
            if (cur.text.trim()) words.push({ text: cur.text.trim(), t: cur.t });
            cur = null;
          }
        }
        if (cur?.text.trim()) words.push({ text: cur.text.trim(), t: cur.t });
        if (words.length) out.push({ t: ms(lead.StartTime), leadEnd: ms(lead.EndTime), words });
      }
      out.sort((a, b) => a.t - b.t);
      // keep each line up a little after its last word, but not past the next line
      for (let i = 0; i < out.length; i++) {
        const next = i + 1 < out.length ? out[i + 1].t : duration || out[i].leadEnd + 4000;
        out[i].end = Math.max(out[i].leadEnd, Math.min(next, out[i].leadEnd + 1500));
        delete out[i].leadEnd;
      }
      return out.length ? out : null;
    }
    if (c.Type === "Line" && Array.isArray(c.Content)) {
      const raw = c.Content.filter((l) => l?.Text != null && l.StartTime != null)
        .map((l) => ({ t: ms(l.StartTime), text: clean(l.Text).trim() }))
        .sort((a, b) => a.t - b.t);
      const lines = build(raw, duration);
      return lines.length ? lines : null;
    }
    return null; // "Static" (no timing) → not useful for a synced overlay
  }

  // ---------- events ----------
  async function onSong() {
    const my = ++reqId;
    const item = Spicetify.Player.data?.item ?? Spicetify.Player.data?.track;
    if (!item?.uri) return;
    const [, kind, id] = item.uri.split(":");
    const meta = item.metadata ?? {};
    const title = meta.title ?? item.name ?? "";
    const artist = meta.artist_name ?? item.artists?.[0]?.name ?? "";
    const album = meta.album_title ?? item.album?.name ?? "";
    const duration = Spicetify.Player.getDuration() || Number(meta.duration) || 0;

    const colorsP = songColors(item); // runs in parallel with the lyrics fetch

    let lines = null;
    let source = "none";
    if (kind === "track") {
      // 1. Spicy Lyrics' cache (real word timing, if it already has this song)
      const sc = await spicyCached(id);
      if (sc) {
        lines = fromSpicy(sc, duration);
        if (lines) source = "spicy-" + sc.Type.toLowerCase();
      }
      // 2. Spotify, then 3. LRCLIB (line timing, word times estimated)
      if (!lines) {
        let raw = null;
        try {
          raw = await spotifyLyrics(id);
          if (raw?.length) source = "spotify";
        } catch (e) {}
        if (!raw?.length) {
          try {
            raw = await lrclibLyrics(title, artist, album, duration);
            if (raw?.length) source = "lrclib";
          } catch (e) {}
        }
        if (raw?.length) lines = build(raw, duration);
      }
    }
    const colors = await colorsP;
    if (my !== reqId) return; // song changed again while fetching

    lastTrack = { type: "track", id, title, artist, source, colors, lines: lines || [] };
    send(lastTrack);
    sendState();

    // Spicy Lyrics fetches in parallel with us; if it wasn't cached yet, watch its cache
    // for ~10 s and upgrade to its (usually word-synced) lyrics when they appear.
    if (kind === "track" && !source.startsWith("spicy")) {
      for (let i = 0; i < 20 && my === reqId; i++) {
        await new Promise((r) => setTimeout(r, 500));
        if (my !== reqId) return;
        const sc = await spicyCached(id);
        const up = sc && fromSpicy(sc, duration);
        if (up && my === reqId) {
          lastTrack = { ...lastTrack, source: "spicy-" + sc.Type.toLowerCase(), lines: up };
          send(lastTrack);
          sendState();
          return;
        }
      }
    }
  }

  let lastSent = 0;
  Spicetify.Player.addEventListener("songchange", onSong);
  Spicetify.Player.addEventListener("onplaypause", sendState);
  Spicetify.Player.addEventListener("onprogress", () => {
    const n = Date.now();
    if (n - lastSent > 400) {
      lastSent = n;
      sendState();
    }
  });

  connect();
  onSong();
})();
