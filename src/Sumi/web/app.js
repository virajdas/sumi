(() => {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const host = window.chrome && window.chrome.webview;
  const send = (msg) => host && host.postMessage(msg);

  const root = document.documentElement;
  const scroller = $("scroller");
  const doc = $("doc");
  const welcome = $("welcome");
  const bar = $("bar");
  const toc = $("toc");
  const tocList = $("toc-list");

  // Preferences: in the app they're kept in settings.ini by the host, which hands them over as
  // window.__sumiPrefs before this script runs. In a plain browser they fall back to localStorage.
  const hostPrefs = window.__sumiPrefs || null;
  const store = {
    get(k, d) {
      if (hostPrefs && k in hostPrefs) return hostPrefs[k];
      try { const v = localStorage.getItem(k); return v === null ? d : v; } catch { return d; }
    },
    set(k, v) {
      v = String(v);
      if (hostPrefs) hostPrefs[k] = v;
      send(`pref:${k}=${v}`);
      try { localStorage.setItem(k, v); } catch {}
    },
  };

  /* ---------- Appearance ---------- */
  const THEMES = ["auto", "light", "sepia", "dark"];
  const LABELS = { auto: "Automatic", light: "Paper", sepia: "Sepia", dark: "Night" };
  const systemDark = matchMedia("(prefers-color-scheme: dark)");
  let theme = store.get("theme", "auto");
  if (!THEMES.includes(theme)) theme = "auto";

  function applyTheme() {
    const resolved = theme === "auto" ? (systemDark.matches ? "dark" : "light") : theme;
    root.dataset.theme = resolved;
    const bg = getComputedStyle(root).getPropertyValue("--bg").trim();
    send(`chrome:${resolved === "dark" ? 1 : 0}:${bg}`);
  }
  systemDark.addEventListener("change", applyTheme);

  function setTheme(next) {
    theme = next;
    store.set("theme", theme);
    applyTheme();
    renderSwatches();
  }
  const cycleTheme = () => setTheme(THEMES[(THEMES.indexOf(theme) + 1) % THEMES.length]);

  /* ---------- Typefaces ---------- */
  const FONTS = [
    { id: "literata",     name: "Literata",              kind: "Book serif",   css: '"Literata"' },
    { id: "newsreader",   name: "Newsreader",            kind: "Editorial",    css: '"Newsreader"', wt: 420 },
    { id: "source-serif", name: "Source Serif",          kind: "Crisp serif",  css: '"Source Serif 4"' },
    { id: "garamond",     name: "EB Garamond",           kind: "Classic",      css: '"EB Garamond"', px: 19, wt: 450 },
    { id: "lora",         name: "Lora",                  kind: "Soft serif",   css: '"Lora"' },
    { id: "bitter",       name: "Bitter",                kind: "Slab",         css: '"Bitter"' },
    { id: "atkinson",     name: "Atkinson Hyperlegible", kind: "Clearest",     css: '"Atkinson Hyperlegible"', px: 16 },
    { id: "nunito",       name: "Nunito",                kind: "Rounded",      css: '"Nunito"', wt: 420 },
    { id: "figtree",      name: "Figtree",               kind: "Clean sans",   css: '"Figtree"' },
    { id: "plex-mono",    name: "Plex Mono",             kind: "Typewriter",   css: '"IBM Plex Mono"', px: 15 },
  ];
  let font = store.get("font", "literata");
  if (!FONTS.some((f) => f.id === font)) font = "literata";

  function setFont(id) {
    font = id;
    store.set("font", id);
    if (id === "literata") delete root.dataset.font;
    else root.dataset.font = id;
    fontList.querySelectorAll("li").forEach((li) => li.setAttribute("aria-selected", String(li.dataset.id === id)));
    if (tocOpen()) layoutToc();
  }
  const cycleFont = (dir) => {
    const i = FONTS.findIndex((f) => f.id === font);
    setFont(FONTS[(i + dir + FONTS.length) % FONTS.length].id);
  };

  const fontList = $("fonts");
  for (const f of FONTS) {
    const li = document.createElement("li");
    li.dataset.id = f.id;
    li.tabIndex = 0;
    li.setAttribute("role", "option");
    li.innerHTML = `<svg class="tick" viewBox="0 0 14 14"><path d="M2.5 7.5l3 3 6-7"/></svg>
      <span class="name"></span><span class="kind"></span>`;
    const name = li.querySelector(".name");
    name.textContent = f.name;
    name.style.fontFamily = `${f.css}, "Literata", serif`;
    if (f.px) name.style.fontSize = f.px + "px";
    if (f.wt) name.style.fontWeight = f.wt;
    li.querySelector(".kind").textContent = f.kind;
    li.addEventListener("click", () => setFont(f.id));
    li.addEventListener("keydown", (e) => {
      if (e.key === "Enter" || e.key === " ") { e.preventDefault(); setFont(f.id); }
      else if (e.key === "ArrowDown") { e.preventDefault(); (li.nextElementSibling || li).focus(); }
      else if (e.key === "ArrowUp") { e.preventDefault(); (li.previousElementSibling || li).focus(); }
    });
    fontList.appendChild(li);
  }

  /* ---------- Text & appearance panel ---------- */
  const typo = $("typo");
  const typeBtn = $("btn-type");
  const swatches = $("themes");
  for (const t of THEMES) {
    const b = document.createElement("button");
    b.className = "swatch";
    b.dataset.v = t;
    b.setAttribute("role", "radio");
    b.innerHTML = "<i></i><span></span>";
    b.querySelector("span").textContent = LABELS[t];
    b.addEventListener("click", () => setTheme(t));
    swatches.appendChild(b);
  }
  function renderSwatches() {
    swatches.querySelectorAll(".swatch").forEach((b) => b.setAttribute("aria-checked", String(b.dataset.v === theme)));
  }
  function toggleTypo(force) {
    const open = force ?? !typo.classList.contains("open");
    typo.classList.toggle("open", open);
    typeBtn.setAttribute("aria-expanded", String(open));
    if (open) showBar();
  }

  const SIZES = [15, 16, 17, 18, 19, 20, 21, 22, 24, 26, 28];
  let size = Math.min(Math.max(parseInt(store.get("size", "19"), 10) || 19, 15), 28);
  function applySize() {
    doc.style.setProperty("--size", size + "px");
    if (tocOpen()) layoutToc();
  }
  function stepSize(dir) {
    let i = SIZES.indexOf(size);
    if (i < 0) i = SIZES.findIndex((s) => s > size) - 1;
    i = Math.min(Math.max(i + dir, 0), SIZES.length - 1);
    size = SIZES[i];
    store.set("size", String(size));
    applySize();
  }

  // Only used when something goes wrong; ordinary changes are their own feedback.
  let toastTimer;
  function toast(text) {
    const t = $("toast");
    t.textContent = text;
    t.classList.add("show");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => t.classList.remove("show"), 3000);
  }

  /* ---------- Rendering ---------- */
  marked.setOptions({ gfm: true, breaks: false });

  const isRelative = (u) => u && !/^([a-z][a-z0-9+.-]*:|\/\/|#)/i.test(u);
  let DOC_BASE = "https://doc.local/"; // the host maps this to the document's folder

  function slugify(text, used) {
    let base = text.toLowerCase().trim()
      .replace(/[^\p{L}\p{N}\s-]/gu, "")
      .replace(/\s+/g, "-") || "section";
    let slug = base, n = 1;
    while (used.has(slug)) slug = `${base}-${n++}`;
    used.add(slug);
    return slug;
  }

  function sanitize(container) {
    container.querySelectorAll("script, iframe, object, embed, link, meta, style, base, form").forEach((n) => n.remove());
    container.querySelectorAll("*").forEach((el) => {
      for (const attr of [...el.attributes]) {
        const name = attr.name.toLowerCase();
        if (name.startsWith("on")) el.removeAttribute(attr.name);
        else if ((name === "href" || name === "src" || name === "xlink:href") && /^\s*(javascript|vbscript):/i.test(attr.value)) {
          el.removeAttribute(attr.name);
        }
      }
    });
  }

  function enhance(container) {
    // Relative images resolve against the document's folder.
    container.querySelectorAll("img[src], source[src], video[src], audio[src]").forEach((el) => {
      const src = el.getAttribute("src");
      if (isRelative(src)) el.setAttribute("src", new URL(src.replace(/\\/g, "/"), DOC_BASE).href);
      el.setAttribute("loading", "lazy");
    });

    // Headings get stable anchors.
    const used = new Set();
    container.querySelectorAll("h1, h2, h3, h4, h5, h6").forEach((h) => {
      if (!h.id) h.id = slugify(h.textContent, used);
      else used.add(h.id);
    });

    // Task lists.
    container.querySelectorAll('li > input[type="checkbox"]').forEach((cb) => {
      cb.disabled = true;
      cb.parentElement.classList.add("task");
    });

    // Tables scroll on their own.
    container.querySelectorAll("table").forEach((t) => {
      const wrap = document.createElement("div");
      wrap.className = "table-wrap";
      t.replaceWith(wrap);
      wrap.appendChild(t);
    });

    // Code blocks get a copy button on hover.
    container.querySelectorAll("pre > code").forEach((code) => {
      const pre = code.parentElement;
      const btn = document.createElement("button");
      btn.className = "copy";
      btn.textContent = "Copy";
      btn.addEventListener("click", () => {
        navigator.clipboard.writeText(code.textContent).then(() => {
          btn.textContent = "Copied";
          setTimeout(() => (btn.textContent = "Copy"), 1200);
        });
      });
      pre.appendChild(btn);
    });
  }

  function buildToc() {
    tocList.innerHTML = "";
    let heads = [...doc.querySelectorAll("h1, h2, h3, h4")];
    if (heads[0] && heads[0].tagName === "H1" && heads[0] === doc.firstElementChild &&
        !heads.slice(1).some((h) => h.tagName === "H1")) heads = heads.slice(1);
    if (!heads.length) {
      tocList.innerHTML = '<li class="empty">This document has no headings.</li>';
      return;
    }
    const top = Math.min(...heads.map((h) => +h.tagName[1]));
    for (const h of heads) {
      const li = document.createElement("li");
      li.className = "d" + Math.min(+h.tagName[1] - top + 1, 3);
      const a = document.createElement("a");
      a.href = "#" + h.id;
      a.textContent = h.textContent;
      a.dataset.target = h.id;
      li.appendChild(a);
      tocList.appendChild(li);
    }
  }

  function render({ name, md, reload }) {
    const keep = reload ? scroller.scrollTop : 0;
    const tpl = document.createElement("template");
    tpl.innerHTML = marked.parse(md.replace(/^﻿/, ""));
    const frag = tpl.content;
    sanitize(frag);
    enhance(frag);

    const first = !doc.childElementCount;
    doc.replaceChildren(frag);
    welcome.hidden = true;
    doc.hidden = false;
    document.title = name;
    buildToc();
    if (first && store.get("toc", "0") === "1" && !isNarrow()) toggleToc(true, false);

    if (reload) {
      scroller.style.scrollBehavior = "auto";
      scroller.scrollTop = keep;
      scroller.style.scrollBehavior = "";
    } else {
      scroller.style.scrollBehavior = "auto";
      scroller.scrollTop = 0;
      scroller.style.scrollBehavior = "";
      doc.classList.remove("enter");
      void doc.offsetWidth;
      doc.classList.add("enter");
      showBar();
    }
    onScroll();
  }

  /* ---------- Chrome behaviour ---------- */
  let lastY = 0, barTimer;
  function showBar() { bar.classList.remove("hidden"); }
  function hideBar() {
    if (!tocOpen() && !typo.classList.contains("open") && !doc.hidden) bar.classList.add("hidden");
  }

  function onScroll() {
    const y = scroller.scrollTop;
    if (y < 40 || y < lastY - 6) showBar();
    else if (y > lastY + 4) hideBar();
    lastY = y;
    markActiveHeading();
  }
  scroller.addEventListener("scroll", onScroll, { passive: true });

  document.addEventListener("mousemove", (e) => {
    if (e.clientY < 64) { showBar(); clearTimeout(barTimer); }
    else if (scroller.scrollTop > 40 && !bar.matches(":hover")) {
      clearTimeout(barTimer);
      barTimer = setTimeout(hideBar, 1400);
    }
  });

  let activeRaf = 0;
  function markActiveHeading() {
    if (!tocOpen() || activeRaf) return;
    activeRaf = requestAnimationFrame(() => {
      activeRaf = 0;
      const links = [...tocList.querySelectorAll("a")];
      let current = null;
      for (const a of links) {
        const h = document.getElementById(a.dataset.target);
        if (h && h.getBoundingClientRect().top < 100) current = a;
      }
      links.forEach((a) => a.classList.toggle("active", a === current));
    });
  }

  const isNarrow = () => innerWidth < 760;
  const tocOpen = () => document.body.classList.contains("toc-open");
  function toggleToc(force, remember = true) {
    const open = force ?? !tocOpen();
    if (open && doc.hidden) return;
    layoutToc();
    document.body.classList.toggle("toc-open", open);
    $("btn-toc").setAttribute("aria-expanded", String(open));
    if (remember && !isNarrow()) store.set("toc", open ? "1" : "0");
    if (open) { showBar(); markActiveHeading(); }
  }

  // The outline sits flush left, in line with the toolbar's contents icon. The column stays centred
  // unless the outline would crowd it, in which case the page steps aside just enough.
  const TOC_W = 200, TOC_GAP = 48, EDGE = 28;
  function layoutToc() {
    const body = document.body;
    const overlay = innerWidth < 760;
    const column = Math.min(innerWidth, parseFloat(getComputedStyle(doc).maxWidth) || innerWidth);
    const textLeft = (innerWidth - column) / 2 + 32;
    const fits = !overlay && textLeft >= EDGE + TOC_W + TOC_GAP;
    body.classList.toggle("toc-overlay", overlay);
    body.classList.toggle("toc-shift", !overlay && !fits);
  }
  addEventListener("resize", layoutToc);

  /* ---------- Links ---------- */
  document.addEventListener("click", (e) => {
    const a = e.target.closest("a[href]");
    if (!a) {
      if (tocOpen() && isNarrow() && !e.target.closest("#toc, #btn-toc")) toggleToc(false, false);
      if (typo.classList.contains("open") && !e.target.closest("#typo, #btn-type")) toggleTypo(false);
      return;
    }
    e.preventDefault();
    const href = a.getAttribute("href");
    if (href.startsWith("#")) {
      const el = document.getElementById(decodeURIComponent(href.slice(1)));
      if (el) el.scrollIntoView({ behavior: "smooth", block: "start" });
      if (a.closest("#toc") && isNarrow()) setTimeout(() => toggleToc(false, false), 250);
      return;
    }
    send("link:" + (isRelative(href) ? new URL(href.replace(/\\/g, "/"), DOC_BASE).href : href));
  });

  /* ---------- Buttons & keys ---------- */
  const open = () => send("open");
  $("btn-open").onclick = open;
  $("welcome-open").onclick = open;
  typeBtn.onclick = (e) => { e.stopPropagation(); toggleTypo(); };
  $("btn-larger").onclick = () => stepSize(1);
  $("btn-smaller").onclick = () => stepSize(-1);
  $("btn-toc").onclick = (e) => { e.stopPropagation(); toggleToc(); };

  document.addEventListener("keydown", (e) => {
    const mod = e.ctrlKey || e.metaKey;
    if (mod && (e.key === "=" || e.key === "+")) { e.preventDefault(); stepSize(1); }
    else if (mod && (e.key === "-" || e.key === "_")) { e.preventDefault(); stepSize(-1); }
    else if (mod && e.key === "0") { e.preventDefault(); size = 19; store.set("size", "19"); applySize(); }
    else if (mod && e.key.toLowerCase() === "o") { e.preventDefault(); open(); }
    else if (mod && e.key.toLowerCase() === "t") { e.preventDefault(); cycleTheme(); }
    else if (mod && e.shiftKey && e.key.toLowerCase() === "f") { e.preventDefault(); cycleFont(1); }
    else if (mod && e.key === "\\") { e.preventDefault(); toggleToc(); }
    else if (e.key === "Escape") {
      if (typo.classList.contains("open")) toggleTypo(false);
      else if (tocOpen() && isNarrow()) toggleToc(false, false);
    }
    else if (!mod && (e.key === " " || e.key === "PageDown" || e.key === "PageUp") && document.activeElement === document.body) {
      e.preventDefault();
      const dir = e.key === "PageUp" || e.shiftKey ? -1 : 1;
      scroller.scrollBy({ top: dir * scroller.clientHeight * 0.85, behavior: "smooth" });
    }
    else if (!mod && (e.key === "Home" || e.key === "End") && document.activeElement === document.body) {
      e.preventDefault();
      scroller.scrollTo({ top: e.key === "Home" ? 0 : scroller.scrollHeight, behavior: "smooth" });
    }
  });

  document.addEventListener("wheel", (e) => {
    if (e.ctrlKey) { e.preventDefault(); stepSize(e.deltaY < 0 ? 1 : -1); }
  }, { passive: false });

  /* ---------- Pointer ---------- */
  // The dot follows the mouse exactly; only its size and shape animate (see #pointer in style.css).
  const pointer = document.createElement("div");
  pointer.id = "pointer";
  pointer.className = "away";
  pointer.setAttribute("aria-hidden", "true");
  pointer.innerHTML = "<i></i>";
  document.body.appendChild(pointer);

  const pointerToggle = $("pointer-toggle");
  const finePointer = matchMedia("(any-hover: hover)").matches;
  let customPointer = store.get("pointer", "sumi") !== "system";
  function applyPointer() {
    const on = customPointer && finePointer;
    root.classList.toggle("sumi-pointer", on);
    pointerToggle.setAttribute("aria-checked", String(customPointer));
  }
  pointerToggle.addEventListener("click", () => {
    customPointer = !customPointer;
    store.set("pointer", customPointer ? "sumi" : "system");
    applyPointer();
  });

  const CLICKABLE = 'a[href], button, summary, label, [role="option"], [role="switch"], [role="radio"]';
  let px = -100, py = -100, framed = false, selecting = false;
  let lineY = null; // vertical centre of the line the text bar is snapped to, or null to follow the mouse

  // Position is applied straight away on every move; in text mode it sits on the snapped line's centre.
  function place() {
    const y = lineY !== null && pointer.classList.contains("text") ? lineY : py;
    pointer.style.transform = `translate3d(${px}px, ${y}px, 0)`;
  }

  // The box of the character under (x, y), or null when the pointer is over empty space rather than a glyph.
  function glyphUnder(x, y) {
    const caret = document.caretRangeFromPoint && document.caretRangeFromPoint(x, y);
    const node = caret && caret.startContainer;
    if (!node || node.nodeType !== 3 || !node.data.trim()) return null;
    const range = document.createRange();
    for (const i of [caret.startOffset - 1, caret.startOffset]) {
      if (i < 0 || i >= node.length) continue;
      range.setStart(node, i);
      range.setEnd(node, i + 1);
      for (const b of range.getClientRects()) {
        if (x >= b.left - 2 && x <= b.right + 2 && y >= b.top - 2 && y <= b.bottom + 2) return b;
      }
    }
    return null;
  }

  function updatePointer() {
    framed = false;
    const sr = scroller.getBoundingClientRect();
    const onScrollbar = px > sr.left + scroller.clientWidth && px <= sr.right;
    pointer.classList.toggle("away", onScrollbar || px < 0);
    if (onScrollbar) return;

    const el = document.elementFromPoint(px, py);
    const clickable = !selecting && el && el.closest(CLICKABLE);
    const glyph = clickable ? null : glyphUnder(px, py);
    if (glyph) {
      // Snap the bar to the middle of the line it's on, sized to that line's letters.
      pointer.style.setProperty("--bar", Math.round(Math.min(Math.max(glyph.height, 14), 72)) + "px");
      lineY = Math.round(glyph.top + glyph.height / 2);
    } else {
      lineY = null; // empty space, or dragging a selection past the end of a line: follow the mouse
    }
    pointer.classList.toggle("hover", !!clickable);
    if (!selecting) pointer.classList.toggle("text", !!glyph);
    place();
  }
  const schedule = () => { if (!framed) { framed = true; requestAnimationFrame(updatePointer); } };

  document.addEventListener("pointermove", (e) => {
    if (e.pointerType === "touch") { pointer.classList.add("away"); return; }
    px = e.clientX; py = e.clientY;
    place();
    schedule(); // shape (and which line to snap to) is worked out in the next frame
  }, { passive: true });
  document.addEventListener("pointerdown", () => {
    selecting = pointer.classList.contains("text"); // dragging out a selection keeps the text bar
    pointer.classList.add("down");
  });
  const release = () => { selecting = false; pointer.classList.remove("down"); schedule(); };
  document.addEventListener("pointerup", release);
  document.addEventListener("pointercancel", release);
  document.documentElement.addEventListener("mouseleave", () => pointer.classList.add("away"));
  scroller.addEventListener("scroll", schedule, { passive: true }); // what's under the pointer changes as the page moves

  /* ---------- Drag & drop ---------- */
  const dropEl = $("drop");
  let dragDepth = 0;
  window.addEventListener("dragenter", (e) => { e.preventDefault(); dragDepth++; dropEl.classList.add("show"); });
  window.addEventListener("dragleave", () => { if (--dragDepth <= 0) { dragDepth = 0; dropEl.classList.remove("show"); } });
  window.addEventListener("dragover", (e) => e.preventDefault());
  window.addEventListener("drop", (e) => {
    e.preventDefault();
    dragDepth = 0;
    dropEl.classList.remove("show");
    const files = e.dataTransfer && e.dataTransfer.files;
    if (files && files.length && host && host.postMessageWithAdditionalObjects) {
      host.postMessageWithAdditionalObjects("drop", files);
    }
  });

  /* ---------- Host messages ---------- */
  if (host) {
    host.addEventListener("message", (e) => {
      const m = e.data;
      if (m.type === "doc") render(m);
      else if (m.type === "toast") toast(m.text);
    });
  }

  applyTheme();
  renderSwatches();
  applySize();
  setFont(font);
  applyPointer();
  send("ready");

  // Outside the app (design preview in a browser): ?demo=<url> renders a file.
  const params = new URLSearchParams(location.search);
  const demo = !host && params.get("demo");
  if (demo) {
    DOC_BASE = new URL(".", new URL(demo, location.href)).href;
    if (params.get("font")) setFont(params.get("font"));
    if (params.get("theme")) setTheme(params.get("theme"));
    fetch(demo).then((r) => r.text()).then((md) => {
      render({ name: demo.split("/").pop(), md });
      if (params.has("panel")) toggleTypo(true);
      if (params.has("toc")) toggleToc(true, false);
      if (params.get("y")) scroller.scrollTop = +params.get("y");
      if (params.get("at")) { // place the pointer for screenshots: at=x,y[,down]
        const [x, y, down] = params.get("at").split(",");
        setTimeout(() => {
          document.dispatchEvent(new PointerEvent("pointermove", { clientX: +x, clientY: +y, pointerType: "mouse" }));
          if (down) setTimeout(() => document.dispatchEvent(new PointerEvent("pointerdown", { pointerType: "mouse" })), 50);
        }, 300);
      }
    });
  }
})();
