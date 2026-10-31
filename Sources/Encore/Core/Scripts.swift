import Foundation

/// JavaScript injected into the two YouTube web views.
///
/// Everything lives in raw string literals so the app stays a single,
/// resource-free executable. The scripts talk to Swift exclusively through
/// `window.webkit.messageHandlers.encore.postMessage({...})`.
enum Scripts {

    // MARK: - Shared

    /// Makes YouTube believe the page is always visible so it never throttles,
    /// pauses or degrades playback when the window is hidden or closed.
    static let visibilitySpoof = #"""
    (() => {
      try {
        const def = (obj, key, value) =>
          Object.defineProperty(obj, key, { configurable: true, get: () => value });
        def(Document.prototype, 'hidden', false);
        def(Document.prototype, 'webkitHidden', false);
        def(Document.prototype, 'visibilityState', 'visible');
        def(Document.prototype, 'webkitVisibilityState', 'visible');
        Document.prototype.hasFocus = () => true;
        const swallow = (e) => e.stopImmediatePropagation();
        document.addEventListener('visibilitychange', swallow, true);
        document.addEventListener('webkitvisibilitychange', swallow, true);
        window.addEventListener('blur', (e) => { if (e.target === window) e.stopImmediatePropagation(); }, true);
      } catch (e) {}
    })();
    """#

    /// Native-feeling scrollbars and a background that matches the app while
    /// YouTube's own CSS is still loading (avoids the white flash).
    static let baseStyle = #"""
    (() => {
      const css = `
        html { background: #0b0a10 !important; }
        ::-webkit-scrollbar { width: 10px; height: 10px; background: transparent; }
        ::-webkit-scrollbar-thumb { background: rgba(255,255,255,.18); border-radius: 10px;
          border: 3px solid transparent; background-clip: content-box; }
        ::-webkit-scrollbar-thumb:hover { background-color: rgba(255,255,255,.32); }
      `;
      const add = () => {
        if (document.getElementById('encore-base')) return;
        const s = document.createElement('style');
        s.id = 'encore-base';
        s.textContent = css;
        (document.head || document.documentElement).appendChild(s);
      };
      if (document.documentElement) add();
      document.addEventListener('DOMContentLoaded', add);
    })();
    """#

    // MARK: - Browser web view

    /// Runs in the browsing web view. It must never play media itself; instead
    /// every click on a video is handed to the native player engine.
    static let browser = #"""
    (() => {
      if (window.__encoreBrowser) return;
      window.__encoreBrowser = true;
      const post = (type, payload) => {
        try { window.webkit.messageHandlers.encore.postMessage(Object.assign({ type }, payload || {})); } catch (e) {}
      };

      // 1. No playback in the browser: kills hover previews and home-page autoplay,
      //    and guarantees this view never competes for Now Playing / media keys.
      const proto = HTMLMediaElement.prototype;
      const blockedPlay = function () {
        try { this.muted = true; this.pause(); } catch (e) {}
        return Promise.reject(new DOMException('Playback is handled by Encore', 'NotAllowedError'));
      };
      Object.defineProperty(proto, 'play', { configurable: true, writable: true, value: blockedPlay });
      setInterval(() => {
        document.querySelectorAll('video, audio').forEach(m => { if (!m.paused) { m.muted = true; m.pause(); } });
      }, 1000);

      // 2. Route video links to the native player.
      const isPlayable = (url) => {
        try {
          const u = new URL(url, location.href);
          if (!/(^|\.)youtube\.com$/.test(u.hostname) && u.hostname !== 'youtu.be') return false;
          if (u.hostname === 'youtu.be') return u.pathname.length > 1;
          return u.pathname === '/watch' || u.pathname.startsWith('/shorts/') || u.pathname.startsWith('/live/');
        } catch (e) { return false; }
      };
      window.addEventListener('click', (e) => {
        if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
        const a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
        if (!a) return;
        const href = a.getAttribute('href');
        if (!href || href.startsWith('#') || href.startsWith('javascript')) return;
        if (!isPlayable(href)) return;
        e.preventDefault();
        e.stopImmediatePropagation();
        post('play', { url: new URL(href, location.href).href });
      }, true);

      // 3. Safety net for programmatic SPA navigations.
      document.addEventListener('yt-navigate-start', (e) => {
        const url = e && e.detail && e.detail.url;
        if (url && isPlayable(url)) post('play', { url: new URL(url, location.href).href, viaRouter: true });
      }, true);

      // 4. Optional "native chrome": hide YouTube's own header and guide.
      const chromeCSS = `
        html.encore-clean #masthead-container,
        html.encore-clean ytd-masthead,
        html.encore-clean tp-yt-app-drawer#guide,
        html.encore-clean #guide,
        html.encore-clean ytd-mini-guide-renderer { display: none !important; }
        html.encore-clean ytd-app { --ytd-masthead-height: 0px !important; --ytd-toolbar-height: 0px !important; }
        html.encore-clean ytd-app[mini-guide-visible] ytd-page-manager,
        html.encore-clean ytd-app ytd-page-manager,
        html.encore-clean #page-manager.ytd-app { margin-left: 0 !important; margin-top: 0 !important; }
        html.encore-clean #frosted-glass, html.encore-clean #header.ytd-rich-grid-renderer { top: 0 !important; }
        html.encore-clean ytd-feed-filter-chip-bar-renderer, html.encore-clean #chips-wrapper { top: 0 !important; }
        html.encore-clean ytd-browse[page-subtype] #primary { padding-top: 12px; }
      `;
      const addChrome = () => {
        if (document.getElementById('encore-chrome')) return;
        const s = document.createElement('style');
        s.id = 'encore-chrome';
        s.textContent = chromeCSS;
        (document.head || document.documentElement).appendChild(s);
      };
      if (document.documentElement) addChrome();
      document.addEventListener('DOMContentLoaded', addChrome);

      window.__encore = {
        setClean(on) { document.documentElement.classList.toggle('encore-clean', !!on); window.dispatchEvent(new Event('resize')); },
      };
      if (window.__encoreInitialClean) window.__encore.setClean(true);

      // 5. Tell native about the signed-in avatar when it shows up.
      let lastAvatar = '';
      setInterval(() => {
        const img = document.querySelector('#avatar-btn img, ytd-topbar-menu-button-renderer img#img');
        const src = img && img.src && img.src.startsWith('http') ? img.src : '';
        if (src && src !== lastAvatar) { lastAvatar = src; post('avatar', { url: src }); }
      }, 3000);
    })();
    """#

    // MARK: - Player web view

    /// Runs in the dedicated playback web view. Exposes a small command API on
    /// `window.__encore`, streams player state and (optionally) audio spectrum
    /// data for the visualisers.
    static let player = #"""
    (() => {
      if (window.__encore) return;
      const post = (type, payload) => {
        try { window.webkit.messageHandlers.encore.postMessage(Object.assign({ type }, payload || {})); } catch (e) {}
      };

      const settings = Object.assign({
        autoSkipAds: true,
        dismissStillWatching: true,
        cinema: true,
        quality: 'auto',
      }, window.__encoreInitial || {});

      // Hold autoplay when restoring the last session on launch.
      let holdAutoplay = location.hash.indexOf('encore-hold') !== -1;

      // ---------- Media Session ----------
      // Encore owns the transport. The page's own handlers are ignored and our
      // handlers forward to native, which de-duplicates against the
      // MPRemoteCommandCenter path so every key press acts exactly once.
      try {
        const ms = navigator.mediaSession;
        if (ms && ms.setActionHandler) {
          const original = ms.setActionHandler.bind(ms);
          const owned = { play: 'play', pause: 'pause', nexttrack: 'next', previoustrack: 'previous',
                          seekforward: 'seekForward', seekbackward: 'seekBackward', stop: 'pause' };
          ms.setActionHandler = function (action, handler) {
            if (action in owned) return;
            try { original(action, handler); } catch (e) {}
          };
          Object.keys(owned).forEach((action) => {
            try { original(action, () => post('remote', { command: owned[action] })); } catch (e) {}
          });
        }
      } catch (e) {}

      // ---------- Player access ----------
      const player = () => document.getElementById('movie_player');
      const video = () =>
        document.querySelector('#movie_player video.html5-main-video') ||
        document.querySelector('#movie_player video') ||
        document.querySelector('video');
      const call = (name, ...args) => {
        const p = player();
        try { if (p && typeof p[name] === 'function') return p[name](...args); } catch (e) {}
        return undefined;
      };
      const isAd = () => {
        const p = player();
        if (!p) return false;
        try { if (typeof p.getPresentingPlayerType === 'function' && p.getPresentingPlayerType(true) === 2) return true; } catch (e) {}
        return p.classList.contains('ad-showing') || p.classList.contains('ad-interrupting');
      };

      const snapshot = () => {
        const p = player();
        const v = video();
        let d = {};
        try { d = (p && p.getVideoData) ? (p.getVideoData() || {}) : {}; } catch (e) {}
        const meta = (navigator.mediaSession && navigator.mediaSession.metadata) || {};
        const params = new URLSearchParams(location.search);
        let id = d.video_id || params.get('v') || '';
        if (!id) {
          const m = location.pathname.match(/^\/(?:shorts|live)\/([\w-]{6,})/);
          if (m) id = m[1];
        }
        const duration = v && isFinite(v.duration) ? v.duration : (call('getDuration') || 0);
        const volume = call('getVolume');
        const muted = call('isMuted');
        // Playability problems (sign-in walls, region locks, removed videos).
        let error = '';
        const visible = (el) => el && el.offsetParent !== null && (el.innerText || '').trim().length > 0;
        const errEl = document.querySelector('#movie_player .ytp-error');
        if (visible(errEl)) error = errEl.innerText.trim().split('\n')[0];
        if (!error) {
          const wall = document.querySelector('yt-playability-error-supported-renderers');
          if (visible(wall)) error = wall.innerText.trim().split('\n')[0];
        }
        return {
          videoId: id,
          title: d.title || meta.title || document.title.replace(/^\s*-\s*/, '').replace(/\s*-\s*YouTube$/, ''),
          author: d.author || meta.artist || '',
          isLive: !!(d.isLive || (v && v.duration === Infinity)),
          currentTime: v ? (v.currentTime || 0) : 0,
          duration: duration || 0,
          paused: v ? v.paused : true,
          ended: v ? v.ended : false,
          buffering: v ? v.readyState < 3 && !v.paused : false,
          rate: v ? v.playbackRate : 1,
          volume: typeof volume === 'number' ? volume : (v ? Math.round(v.volume * 100) : 100),
          muted: typeof muted === 'boolean' ? muted : (v ? v.muted : false),
          isAd: isAd(),
          playlistId: params.get('list') || '',
          url: location.href,
          isWatch: !!id,
          error,
        };
      };

      let lastPost = 0;
      let lastKey = '';
      const pushState = (force) => {
        const s = snapshot();
        const key = [s.videoId, s.title, s.author, s.paused, s.isAd, s.rate, s.volume, s.muted, Math.round(s.duration), s.error].join('|');
        const now = Date.now();
        if (!force && key === lastKey && now - lastPost < 1000) return;
        lastKey = key;
        lastPost = now;
        post('state', s);
      };

      // ---------- Quality ----------
      const applyQuality = () => {
        const q = settings.quality;
        if (!q || q === 'auto') { call('setPlaybackQualityRange', 'auto', 'auto'); return; }
        const levels = call('getAvailableQualityLevels') || [];
        let target = q;
        if (levels.length && levels.indexOf(q) === -1) {
          // pick the closest available level, preferring lower ones
          const order = ['tiny', 'small', 'medium', 'large', 'hd720', 'hd1080', 'hd1440', 'hd2160', 'highres'];
          const want = order.indexOf(q);
          const avail = levels.filter(l => order.indexOf(l) !== -1).sort((a, b) => order.indexOf(a) - order.indexOf(b));
          target = avail.reduce((best, l) => (order.indexOf(l) <= want ? l : best), avail[0] || q);
        }
        call('setPlaybackQualityRange', target, target);
        call('setPlaybackQuality', target);
      };

      // ---------- Cinema layout ----------
      const cinemaCSS = `
        html.encore-cinema, html.encore-cinema body { overflow: hidden !important; background: #000 !important; }
        html.encore-cinema #movie_player {
          position: fixed !important; inset: 0 !important; width: 100vw !important; height: 100vh !important;
          max-height: none !important; z-index: 2147483000 !important; background: #000 !important; }
        html.encore-cinema #masthead-container, html.encore-cinema ytd-masthead,
        html.encore-cinema tp-yt-app-drawer#guide { visibility: hidden !important; }
        html.encore-cinema .ytp-miniplayer-button, html.encore-cinema .ytp-size-button { display: none !important; }
        html.encore-hide-player #movie_player video { visibility: hidden !important; }
      `;
      const addCinemaStyle = () => {
        if (document.getElementById('encore-cinema')) return;
        const s = document.createElement('style');
        s.id = 'encore-cinema';
        s.textContent = cinemaCSS;
        (document.head || document.documentElement).appendChild(s);
      };
      const applyCinema = () => {
        addCinemaStyle();
        document.documentElement.classList.toggle('encore-cinema', !!settings.cinema);
        window.dispatchEvent(new Event('resize'));
      };
      if (document.documentElement) applyCinema();
      document.addEventListener('DOMContentLoaded', applyCinema);

      // ---------- Video element wiring ----------
      let wired = null;
      let lastVideoId = '';
      const onEvent = () => pushState(true);
      const wire = () => {
        const v = video();
        if (!v || v === wired) return;
        if (wired) ['play', 'pause', 'playing', 'seeked', 'ratechange', 'durationchange', 'ended', 'loadedmetadata', 'volumechange', 'waiting']
          .forEach(n => wired.removeEventListener(n, onEvent));
        wired = v;
        ['play', 'pause', 'playing', 'seeked', 'ratechange', 'durationchange', 'ended', 'loadedmetadata', 'volumechange', 'waiting']
          .forEach(n => v.addEventListener(n, onEvent));
        v.addEventListener('playing', () => {
          if (holdAutoplay) { holdAutoplay = false; try { v.pause(); } catch (e) {} }
          viz.resume();
        });
        v.addEventListener('loadeddata', applyQuality);
      };

      // Periodic housekeeping: rewire, ads, "still watching?", state heartbeat.
      setInterval(() => {
        wire();
        const s = snapshot();
        if (s.videoId && s.videoId !== lastVideoId) {
          lastVideoId = s.videoId;
          applyQuality();
          applyCinema();
          pushState(true);
        }
        if (settings.autoSkipAds && s.isAd) {
          const skip = document.querySelector('.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-ad-skip-button-container button');
          if (skip) skip.click();
        }
        if (settings.dismissStillWatching) {
          const dialog = document.querySelector('ytd-popup-container yt-confirm-dialog-renderer, ytd-popup-container tp-yt-paper-dialog');
          if (dialog && dialog.offsetParent !== null) {
            const btn = dialog.querySelector('#confirm-button button, #confirm-button, yt-button-renderer[dialog-confirm] button');
            if (btn && /watch|continue|yes/i.test((dialog.innerText || ''))) { btn.click(); setTimeout(() => call('playVideo'), 250); }
          }
        }
        pushState(false);
      }, 500);

      // ---------- Visualiser (Web Audio analyser) ----------
      const viz = {
        active: false, bands: 56, ctx: null, analyser: null, el: null, freq: null, time: null, timer: null, warned: false,
        resume() { if (this.ctx && this.ctx.state !== 'running') { this.ctx.resume().catch(() => {}); } },
        graph() {
          const v = video();
          if (!v) return false;
          if (this.el === v && this.analyser) return true;
          // Only hook MediaSource (blob:) playback. Cross-origin progressive/HLS
          // media is "tainted" and would be silenced by Web Audio.
          const src = v.currentSrc || v.src || '';
          if (!src.startsWith('blob:')) return false;
          try {
            const AC = window.AudioContext || window.webkitAudioContext;
            if (!AC) return false;
            if (!this.ctx) {
              this.ctx = new AC({ latencyHint: 'playback' });
              this.ctx.onstatechange = () => { if (this.ctx.state !== 'running' && wired && !wired.paused) this.resume(); };
            }
            if (this.ctx.state !== 'running') { this.resume(); return false; }
            const source = this.ctx.createMediaElementSource(v);
            const an = this.ctx.createAnalyser();
            an.fftSize = 4096;
            an.smoothingTimeConstant = 0.6;
            an.minDecibels = -92;
            an.maxDecibels = -18;
            source.connect(an);
            an.connect(this.ctx.destination);
            this.analyser = an;
            this.el = v;
            this.freq = new Uint8Array(an.frequencyBinCount);
            this.time = new Uint8Array(an.fftSize);
            post('vizStatus', { ok: true });
            return true;
          } catch (e) {
            if (!this.warned) { this.warned = true; post('vizStatus', { ok: false, reason: String(e) }); }
            return false;
          }
        },
        frame() {
          if (!this.graph()) return;
          const an = this.analyser;
          an.getByteFrequencyData(this.freq);
          an.getByteTimeDomainData(this.time);
          const n = this.bands, len = this.freq.length, nyq = this.ctx.sampleRate / 2;
          const lo = 30, hi = 16000, out = new Array(n);
          for (let i = 0; i < n; i++) {
            const f0 = lo * Math.pow(hi / lo, i / n), f1 = lo * Math.pow(hi / lo, (i + 1) / n);
            const b0 = Math.min(len - 1, Math.floor(f0 / nyq * len));
            const b1 = Math.min(len, Math.max(b0 + 1, Math.ceil(f1 / nyq * len)));
            let peak = 0, sum = 0;
            for (let b = b0; b < b1; b++) { const x = this.freq[b]; sum += x; if (x > peak) peak = x; }
            out[i] = Math.round(peak * 0.6 + (sum / (b1 - b0)) * 0.4);
          }
          let rms = 0;
          for (let i = 0; i < this.time.length; i += 4) { const x = (this.time[i] - 128) / 128; rms += x * x; }
          rms = Math.sqrt(rms / (this.time.length / 4));
          post('viz', { b: out, l: Math.round(Math.min(1, rms * 2.2) * 255) });
        },
        setActive(on) {
          this.active = !!on;
          if (this.active && !this.timer) {
            this.timer = setInterval(() => { if (wired && !wired.paused) this.frame(); }, 33);
          } else if (!this.active && this.timer) {
            clearInterval(this.timer); this.timer = null;
          }
        },
      };

      // ---------- Command API (called from Swift) ----------
      window.__encore = {
        snapshot,
        play() { holdAutoplay = false; viz.resume(); if (call('playVideo') === undefined) { const v = video(); v && v.play(); } pushState(true); },
        pause() { if (call('pauseVideo') === undefined) { const v = video(); v && v.pause(); } pushState(true); },
        seek(t) { if (isAd()) return; if (call('seekTo', t, true) === undefined) { const v = video(); if (v) v.currentTime = t; } setTimeout(() => pushState(true), 150); },
        seekBy(dt) { const v = video(); if (v) this.seek(Math.max(0, (v.currentTime || 0) + dt)); },
        next() {
          if (call('nextVideo') === undefined) { const b = document.querySelector('.ytp-next-button'); b && b.click(); }
          setTimeout(() => pushState(true), 400);
        },
        previous() {
          const v = video();
          if (v && v.currentTime > 4) { this.seek(0); return 'restarted'; }
          const params = new URLSearchParams(location.search);
          if (params.get('list')) { call('previousVideo'); return 'playlist'; }
          return 'history';
        },
        setVolume(vol) { call('setVolume', Math.max(0, Math.min(100, vol))); if (vol > 0) call('unMute'); pushState(true); },
        setMuted(m) { m ? call('mute') : call('unMute'); pushState(true); },
        setRate(r) { const v = video(); if (call('setPlaybackRate', r) === undefined && v) v.playbackRate = r; },
        setQuality(q) { settings.quality = q; applyQuality(); },
        setCinema(on) { settings.cinema = !!on; applyCinema(); },
        setHideVideo(on) { addCinemaStyle(); document.documentElement.classList.toggle('encore-hide-player', !!on); },
        setAutoSkipAds(on) { settings.autoSkipAds = !!on; },
        setDismissStillWatching(on) { settings.dismissStillWatching = !!on; },
        setVisualizer(on) { viz.setActive(on); },
        forceState() { pushState(true); },
      };

      // Leaving the watch page inside the player view would stop playback, so
      // non-video links open in the browser view instead.
      window.addEventListener('click', (e) => {
        if (e.button !== 0) return;
        const a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
        if (!a) return;
        const href = a.getAttribute('href') || '';
        if (!href || href.startsWith('#') || href.startsWith('javascript')) return;
        let u;
        try { u = new URL(href, location.href); } catch (err) { return; }
        const playable = u.pathname === '/watch' || u.pathname.startsWith('/shorts/') || u.pathname.startsWith('/live/');
        if (playable && /(^|\.)youtube\.com$/.test(u.hostname)) return; // keep in player
        e.preventDefault();
        e.stopImmediatePropagation();
        post('browse', { url: u.href });
      }, true);

      post('ready', {});
    })();
    """#
}
