"use strict";

const fs = require("node:fs/promises");
const path = require("node:path");
const { pathToFileURL } = require("node:url");
const { chromium } = require("playwright");

const previewPath = path.resolve(__dirname, "..", "preview", "index.html");
const evidencePath = path.resolve(__dirname, "..", "preview", "evidence");
const chromePath = process.env.CHROME_PATH;
if (!chromePath) {
  throw new Error("Set CHROME_PATH to an existing Chrome executable; this script does not install a browser.");
}

(async () => {
  await fs.mkdir(evidencePath, { recursive: true });
  const browser = await chromium.launch({ headless: true, executablePath: chromePath });
  try {
    const results = [];
    for (const viewport of [{ width: 1280, height: 900 }, { width: 1024, height: 768 }]) {
      const page = await browser.newPage({ viewport, deviceScaleFactor: 1 });
      page.on("pageerror", error => { throw error; });
      await page.goto(pathToFileURL(previewPath).href, { waitUntil: "load" });
      if (!(await page.locator("#usageSelector").isDisabled()) || (await page.locator("#usageSelector").inputValue()) !== "FTX-1 个人终端") {
        throw new Error("The offline use selector must stay disabled on the personal terminal default.");
      }
      for (const mode of ["offline", "demo"]) {
        if (mode === "demo") await page.getByRole("button", { name: "演示通话" }).click();
        else await page.getByRole("button", { name: "未接核心" }).click();
        const layout = await page.evaluate(() => {
          const width = window.innerWidth;
          const height = window.innerHeight;
          const root = document.querySelector(".shell");
          const visibleNodes = [...document.querySelectorAll("body *")].filter(node => {
            const style = getComputedStyle(node);
            return style.display !== "none" && style.visibility !== "hidden" && node.getClientRects().length > 0;
          });
          const outOfBounds = visibleNodes.flatMap(node => {
            const rect = node.getBoundingClientRect();
            return rect.left < -1 || rect.top < -1 || rect.right > width + 1 || rect.bottom > height + 1
              ? [node.id || node.className || node.tagName]
              : [];
          });
          return {
            viewport: { width, height },
            document: { width: document.documentElement.scrollWidth, height: document.documentElement.scrollHeight },
            shell: { clientWidth: root.clientWidth, scrollWidth: root.scrollWidth, clientHeight: root.clientHeight, scrollHeight: root.scrollHeight },
            outOfBounds
          };
        });
        if (layout.document.width > viewport.width || layout.document.height > viewport.height || layout.outOfBounds.length) {
          throw new Error(`${mode} layout overflow at ${viewport.width}x${viewport.height}: ${JSON.stringify(layout)}`);
        }
        const fileName = `${mode}_${viewport.width}x${viewport.height}.png`;
        await page.screenshot({ path: path.join(evidencePath, fileName), fullPage: true });
        results.push({ mode, ...layout, screenshot: fileName });
      }
      await page.close();
    }
    process.stdout.write(`${JSON.stringify(results, null, 2)}\n`);
  } finally {
    await browser.close();
  }
})().catch(error => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exitCode = 1;
});