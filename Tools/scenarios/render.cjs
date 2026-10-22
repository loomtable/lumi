// Renders scenario screens and checks answer cards, with Playwright (no package dependency:
// run through Tools/scenarios/pw, which pins playwright@1.64.0 via npx).
//
//   pw render.cjs screens <Scenarios/cases> <outDir>        → <outDir>/<id>.png (1280×800, the packet's appearance)
//   pw render.cjs cards <cards.jsonl> <report.json>          → each {id, shape, card_html} in light and dark
//
// Card check ("cards render in both themes without overflow"): the HTML is placed in a
// reading well at the card width (chip 26em, card 22em, rich 36em; SF 15pt text, tokens from
// the overlay) and fails if anything overflows horizontally or text contrast against the well is under 3:1.
const fs = require("fs");
const path = require("path");
const { chromium } = require("playwright");

const WELL = { light: { bg: "#FBFAF7", fg: "#1B1C20" }, dark: { bg: "#16181D", fg: "#F2EFEA" } };
// The card palette the app defines (BuddyOverlay/CardWebView.swift); keep in step.
const PALETTE = {
  light: "--text:#1B1C20;--secondary:#5A606B;--ember:#B4451F;--sage:#1F7A4F;--amber:#8A5A00;--rose:#B42318;--mist:#2F6488",
  dark: "--text:#F2EFEA;--secondary:#A9AEB8;--ember:#FF8A5B;--sage:#7FD1A8;--amber:#F5C060;--rose:#FF7B7B;--mist:#8FB8D8",
};
const WIDTH = { chip: "26em", card: "22em", rich: "36em" };

async function screens(root, outDir) {
  fs.mkdirSync(outDir, { recursive: true });
  const browser = await chromium.launch();
  let n = 0;
  for (const id of fs.readdirSync(root).sort()) {
    const dir = path.join(root, id);
    if (!fs.existsSync(path.join(dir, "screen.html")) || !fs.existsSync(path.join(dir, "scenario.json"))) continue;
    const s = JSON.parse(fs.readFileSync(path.join(dir, "scenario.json"), "utf8"));
    const scheme = s.packet?.display?.appearance === "dark" ? "dark" : "light";
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 }, colorScheme: scheme, javaScriptEnabled: false });
    await page.goto("file://" + path.resolve(dir, "screen.html"));
    await page.screenshot({ path: path.join(outDir, id + ".png") });
    await page.close();
    n++;
  }
  await browser.close();
  console.log(`rendered ${n} screens to ${outDir}`);
}

function wellHTML(card, shape, theme) {
  const t = WELL[theme];
  return `<!doctype html><html><head><meta charset="utf-8"><style>
    :root{${PALETTE[theme]}}
    html,body{margin:0;background:${t.bg};color:${t.fg};font:15px -apple-system,"Helvetica Neue",sans-serif;color-scheme:${theme}}
    #well{width:${WIDTH[shape] || WIDTH.card};padding:14px;box-sizing:content-box;overflow:visible}
  </style></head><body><div id="well">${card}</div></body></html>`;
}

async function cards(input, reportPath) {
  const items = fs.readFileSync(input, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
  const browser = await chromium.launch();
  const results = [];
  for (const item of items) {
    const r = { id: item.id, run: item.run, shape: item.shape, themes: {} };
    if (/<script|\bon[a-z]+\s*=|javascript:/i.test(item.card_html || "")) {
      // Cards are static HTML; the app's web view runs them with JavaScript off.
      r.pass = false;
      r.reason = "card contains script";
      results.push(r);
      continue;
    }
    for (const theme of ["light", "dark"]) {
      // Measuring the layout needs page.evaluate; the card itself still gets no JavaScript.
      const page = await browser.newPage({ viewport: { width: 900, height: 900 }, colorScheme: theme, javaScriptEnabled: false });
      await page.setContent(wellHTML(item.card_html || "", item.shape, theme));
      r.themes[theme] = await page.evaluate(() => {
        const well = document.getElementById("well");
        const box = well.getBoundingClientRect();
        const overflow = [];
        for (const el of well.querySelectorAll("*")) {
          const b = el.getBoundingClientRect();
          if (b.width && (b.right > box.right + 1 || b.left < box.left - 1)) overflow.push(el.tagName.toLowerCase());
          if (el.scrollWidth > el.clientWidth + 1 && getComputedStyle(el).overflowX === "visible") overflow.push(el.tagName.toLowerCase() + "(scroll)");
        }
        const lum = (c) => {
          const m = c.match(/[\d.]+/g); if (!m) return null;
          const [r, g, b] = m.slice(0, 3).map((v) => { v = v / 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; });
          return 0.2126 * r + 0.7152 * g + 0.0722 * b;
        };
        const bgOf = (el) => { // nearest opaque background
          for (let e = el; e; e = e.parentElement) {
            const c = getComputedStyle(e).backgroundColor;
            const a = c.match(/rgba?\(([^)]+)\)/); if (!a) continue;
            const parts = a[1].split(",").map(Number);
            if (parts.length < 4 || parts[3] > 0.5) return c;
          }
          return getComputedStyle(document.body).backgroundColor;
        };
        let worst = 21, worstText = null;
        const walker = document.createTreeWalker(well, NodeFilter.SHOW_TEXT);
        for (let n = walker.nextNode(); n; n = walker.nextNode()) {
          if (!n.textContent.trim()) continue;
          const el = n.parentElement, fg = lum(getComputedStyle(el).color), bg = lum(bgOf(el));
          if (fg == null || bg == null) continue;
          const ratio = (Math.max(fg, bg) + 0.05) / (Math.min(fg, bg) + 0.05);
          if (ratio < worst) { worst = ratio; worstText = n.textContent.trim().slice(0, 40); }
        }
        return { overflow: [...new Set(overflow)], minContrast: Math.round(worst * 100) / 100, worstText };
      });
      r.themes[theme].pass = r.themes[theme].overflow.length === 0 && r.themes[theme].minContrast >= 3;
      await page.close();
    }
    r.pass = r.themes.light.pass && r.themes.dark.pass;
    results.push(r);
  }
  await browser.close();
  fs.writeFileSync(reportPath, JSON.stringify(results, null, 2));
  const failed = results.filter((r) => !r.pass);
  console.log(`cards: ${results.length - failed.length}/${results.length} pass in both themes`);
  for (const f of failed) console.log(`  FAIL ${f.id} run ${f.run}: ${f.reason || `light ${JSON.stringify(f.themes.light)} dark ${JSON.stringify(f.themes.dark)}`}`);
}

const [mode, a, b] = process.argv.slice(2);
(mode === "screens" ? screens(a, b) : mode === "cards" ? cards(a, b) : Promise.reject(new Error("usage: screens|cards")))
  .catch((e) => { console.error(e); process.exit(1); });
