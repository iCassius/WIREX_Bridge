"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const path = require("node:path");
const { pathToFileURL } = require("node:url");
const { chromium } = require("playwright");

const prototypePath = path.join(__dirname, "index.html");
const evidenceDirectory = path.resolve(process.argv[2] || "build/_work/R105-ui-prototype");
const chromePath = process.env.CHROME_PATH || "C:/Program Files/Google/Chrome/Application/chrome.exe";
const results = [];

function check(name, condition, detail = "") {
  assert.ok(condition, `${name}${detail ? `: ${detail}` : ""}`);
  results.push({ check: name, result: "passed", detail });
}

async function click(page, selector) {
  await page.locator(selector).click();
}

async function text(page, selector) {
  return (await page.locator(selector).innerText()).trim();
}

async function main() {
  await fs.mkdir(evidenceDirectory, { recursive: true });
  const browser = await chromium.launch({ headless: true, executablePath: chromePath });
  try {
    const page = await browser.newPage({ viewport: { width: 1640, height: 1220 }, deviceScaleFactor: 1 });
    const unexpectedRequests = [];
    page.on("request", request => {
      if (!request.url().startsWith("file://")) unexpectedRequests.push(request.url());
    });
    page.on("pageerror", error => { throw error; });
    await page.goto(pathToFileURL(prototypePath).href, { waitUntil: "load" });

    const staticStatus = await text(page, '[data-channel="91:2"] .remote-detail');
    const staticSource = await text(page, '[data-channel="91:2"] .remote-title');
    const cardCount = async () => page.locator(".subscription-row[data-channel]").count();

    check("default mode is Selected", await page.locator('[data-mode="Selected"]').getAttribute("aria-pressed") === "true");
    check("static API source is shown separately", staticSource.includes("静态") && staticStatus.includes("模拟读回"));
    check("receive-only transmit targets stay disabled", await page.locator('[data-channel="91:2"] [data-action="set-tx"]').isDisabled() && await page.locator('[data-channel="46001:2"] [data-action="set-tx"]').isDisabled());
    check("current selected call starts in simulated local playback", (await text(page, "#currentCallBadge")).includes("播放中") && (await text(page, "#currentMediaPill")).includes("1 playing"));
    check("active RX owns the single media lane and blocks PTT", await page.locator('[data-action="simulate-ptt-down"]').isDisabled() && (await text(page, "#rxOwnerPill")).includes("active"));
    await page.screenshot({ path: path.join(evidenceDirectory, "overview.png"), fullPage: true });

    await click(page, '[data-channel="91:2"] [data-action="toggle-listen"]');
    check("Selected stop changes local policy only", (await text(page, '[data-channel="91:2"] .local-cell')).includes("未监听"));
    check("Selected stop preserves BM static readback", await text(page, '[data-channel="91:2"] .remote-detail') === staticStatus && await text(page, '[data-channel="91:2"] .remote-title') === staticSource);
    check("stopping active RX stops playback but retains rx_stopping owner", (await text(page, "#currentCallBadge")).includes("收尾中") && (await text(page, "#currentMediaPill")).includes("owner busy") && (await text(page, "#rxOwnerPill")).includes("rx_stopping"));
    check("PTT remains busy until simulated HRI T0 cleanup completes", await page.locator('[data-action="simulate-ptt-down"]').isDisabled() && !await page.locator('[data-action="simulate-rx-cleanup"]').isDisabled());
    const pttBypass = page.locator('[data-action="simulate-ptt-down"]');
    await pttBypass.evaluate(element => { element.disabled = false; element.click(); });
    check("direct PTT event is rejected during RX cleanup", (await text(page, "#leaseLabel")).includes("空闲") && (await text(page, "#txStatusSummary")).includes("RX 收尾中"));
    await page.evaluate(() => document.querySelector("#toast").classList.remove("visible"));
    await page.waitForTimeout(250);
    await page.screenshot({ path: path.join(evidenceDirectory, "rx-stopping-awaiting-t0.png"), fullPage: true });
    await click(page, '[data-action="simulate-rx-cleanup"]');
    check("HRI T0 cleanup confirmation releases RX owner", (await text(page, "#rxOwnerPill")).includes("idle") && (await text(page, "#currentMediaPill")).includes("owner idle") && !await page.locator('[data-action="simulate-ptt-down"]').isDisabled());
    await page.evaluate(() => document.querySelector("#toast").classList.remove("visible"));
    await page.waitForTimeout(250);
    await page.screenshot({ path: path.join(evidenceDirectory, "rx-cleanup-complete.png"), fullPage: true });
    await click(page, '[data-channel="91:2"] [data-action="toggle-listen"]');
    check("Selected allows multiple channels", (await text(page, '[data-channel="91:2"] .local-cell')).includes("本地收听中") && (await text(page, '[data-channel="3349:1"] .local-cell')).includes("本地收听中"));
    check("adding RX allow after cleanup does not replay the old stream", (await text(page, "#currentCallBadge")).includes("播放已停") && (await text(page, "#currentMediaPill")).includes("owner idle"));

    const txTargetBeforePrivate = await text(page, "#currentTxTarget");
    await click(page, '[data-action="toggle-private-listen"]');
    check("private peer RX switch is independent of TX", (await text(page, '[data-action="toggle-private-listen"]')).includes("peer 未选") && await text(page, "#currentTxTarget") === txTargetBeforePrivate);
    await click(page, '[data-action="toggle-private-listen"]');
    await click(page, '[data-private-mode="all_peers_to_local"]');
    check("private AllPeers mode is separate from group mode and TX", (await text(page, "#privateModeDescription")).includes("所有") && await page.locator('[data-mode="Selected"]').getAttribute("aria-pressed") === "true" && await text(page, "#currentTxTarget") === txTargetBeforePrivate);
    await click(page, '[data-private-mode="selected_peers"]');

    await click(page, '[data-mode="AllDelivered"]');
    check("AllDelivered mode selects only validated delivered group calls", (await text(page, "#modeDescription")).includes("BM 已送达"));
    await click(page, '[data-channel="91:2"] [data-action="toggle-listen"]');
    const tg91Ts2Button = page.locator('[data-channel="91:2"] [data-action="toggle-listen"]');
    check("AllDelivered stop blocks exact TG/TS channel", (await tg91Ts2Button.innerText()).includes("已排除"));
    await click(page, '[data-mode="Selected"]');
    await click(page, '[data-mode="AllDelivered"]');
    check("mode changes do not clear existing channel block", (await tg91Ts2Button.innerText()).includes("已排除"));

    const beforeNew = await cardCount();
    await click(page, '[data-action="simulate-new-group"]');
    check("new TG creates one candidate without changing prior channel block", await cardCount() === beforeNew + 1 && (await tg91Ts2Button.innerText()).includes("已排除"));
    await click(page, '[data-action="simulate-same-tg-slot"]');
    check("same TG on TS1 is independent from TS2 block", await cardCount() === beforeNew + 2 && (await text(page, '[data-channel="91:1"] .local-cell')).includes("BM 送达即收"));
    check("receive-only TG91 candidate cannot transmit or Quick-call join", await page.locator('[data-channel="91:1"] [data-action="set-tx"]').isDisabled() && await page.locator('[data-channel="91:1"] [data-action="quick-call"]').isDisabled());
    const bypassQuickCall = page.locator('[data-channel="91:1"] [data-action="quick-call"]');
    await bypassQuickCall.evaluate(element => { element.disabled = false; element.click(); });
    check("Quick-call handler rejects direct TG91 bypass", await page.locator("#modalBackdrop").isHidden() && (await text(page, "#toast")).includes("只收预设"));
    const txBeforeBypass = await text(page, "#currentTxTarget");
    const bypassRowTarget = page.locator('[data-channel="91:2"] [data-action="set-tx"]');
    await bypassRowTarget.evaluate(element => { element.disabled = false; element.click(); });
    check("channel TX handler rejects direct TG91 row bypass", await text(page, "#currentTxTarget") === txBeforeBypass && (await text(page, "#toast")).includes("只收预设"));
    const bypassTargetShortcut = page.locator('[data-action="set-target"][data-target="TG 91"]');
    await bypassTargetShortcut.evaluate(element => { element.disabled = false; element.click(); });
    check("TX target handler rejects direct TG91 target edit", await text(page, "#currentTxTarget") === txBeforeBypass && (await text(page, "#toast")).includes("只收预设"));

    const beforeSpeakerSwap = await cardCount();
    await click(page, '[data-action="simulate-speaker"]');
    check("new speaker on TG91 does not create another TG card", await cardCount() === beforeSpeakerSwap && (await text(page, "#speakerId")).includes("3141593"));
    await click(page, '[data-action="toggle-source"]');
    check("speaker block applies by ID across all routes", (await text(page, "#sourceBlockNote")).includes("全路由") && (await text(page, "#sourceBlockNote")).includes("3141593"));
    await click(page, '[data-action="simulate-speaker"]');
    await click(page, '[data-action="simulate-speaker"]');
    check("returning to blocked speaker keeps block and group channel count", await cardCount() === beforeSpeakerSwap && (await text(page, '[data-action="toggle-source"]')).includes("已屏蔽"));

    const modeBeforeTarget = await page.locator('[data-mode="AllDelivered"]').getAttribute("aria-pressed");
    const remoteBeforeTarget = await page.locator(".subscription-row[data-channel] .remote-title").allInnerTexts();
    await click(page, '[data-action="set-target"][data-target="TG 50500"]');
    check("TX target shortcut changes no RX mode or BM state", await page.locator('[data-mode="AllDelivered"]').getAttribute("aria-pressed") === modeBeforeTarget && JSON.stringify(await page.locator(".subscription-row[data-channel] .remote-title").allInnerTexts()) === JSON.stringify(remoteBeforeTarget));
    check("TX target shortcut only updates next target", await text(page, "#currentTxTarget") === "TG 50500");

    await click(page, '[data-action="simulate-ptt-down"]');
    check("PTT down freezes active lease and reports it in the header", (await text(page, "#leaseLabel")).includes("TG 50500") && (await text(page, "#txStatusSummary")).includes("TG 50500") && !(await page.locator('[data-action="set-target"]').first().isDisabled()));
    await click(page, '.target-grid [data-action="set-target"][data-target="TG 3100"]');
    check("target selection during PTT updates pending target only", (await text(page, "#leaseLabel")).includes("TG 50500") && await text(page, "#currentTxTarget") === "TG 3100");
    await page.evaluate(() => document.querySelector("#toast").classList.remove("visible"));
    await page.waitForTimeout(250);
    await page.screenshot({ path: path.join(evidenceDirectory, "tx-lease-frozen.png"), fullPage: true });
    await click(page, '[data-action="simulate-ptt-release"]');
    check("release keeps old target frozen and permits another pending target selection", (await text(page, "#leaseLabel")).includes("TG 50500") && !(await page.locator('[data-action="set-target"]').first().isDisabled()));
    await click(page, '.target-grid [data-action="set-target"][data-target="ID 800001"]');
    check("latest target selected during EOT cleanup remains pending", (await text(page, "#leaseLabel")).includes("TG 50500") && await text(page, "#currentTxTarget") === "ID 800001");
    await click(page, '[data-action="simulate-eot"]');
    check("EOT completion releases the lease with latest pending target selected", (await text(page, "#leaseLabel")).includes("空闲") && await text(page, "#currentTxTarget") === "ID 800001");
    await click(page, '[data-action="simulate-ptt-down"]');
    check("next PTT lease starts with target selected before EOT completed", (await text(page, "#leaseLabel")).includes("ID 800001") && (await text(page, "#txStatusSummary")).includes("ID 800001"));
    await page.evaluate(() => document.querySelector("#toast").classList.remove("visible"));
    await page.waitForTimeout(250);
    await page.screenshot({ path: path.join(evidenceDirectory, "tx-next-lease.png"), fullPage: true });
    await click(page, '[data-action="simulate-ptt-release"]');
    await click(page, '[data-action="simulate-eot"]');

    await click(page, '[data-channel="3100:2"] [data-action="quick-call"]');
    check("dynamic Quick call displays explicit network-call confirmation", (await text(page, "#modalBody")).includes("向网络发送一次短 DMR 组呼"));
    await click(page, "#modalActions .button.warn");
    check("demo Quick call confirmation sends no network request", (await text(page, "#toast")).includes("没有发送"));

    await click(page, '[data-action="preview-static"]');
    check("static API difference is a local preview with apply disabled", (await text(page, "#modalBody")).includes("待添加") && await page.locator("#modalActions .button").last().isDisabled());
    await click(page, "#modalActions .button.quiet");

    const source = await fs.readFile(prototypePath, "utf8");
    check("prototype source has no network or browser persistence API calls", !/(?:\bfetch\s*\(|new\s+XMLHttpRequest|new\s+WebSocket|localStorage\s*[\[.]|sessionStorage\s*[\[.]|indexedDB\s*[\[.])/.test(source));
    check("browser made no network requests", unexpectedRequests.length === 0, unexpectedRequests.join(", "));

    await page.goto(pathToFileURL(prototypePath).href, { waitUntil: "load" });
    await click(page, '[data-mode="AllDelivered"]');
    await click(page, '[data-channel="91:2"] [data-action="toggle-listen"]');
    await click(page, '[data-action="simulate-new-group"]');
    await page.evaluate(() => document.querySelector("#toast").classList.remove("visible"));
    await page.waitForTimeout(250);
    await page.screenshot({ path: path.join(evidenceDirectory, "all-delivered-with-local-block.png"), fullPage: true });

    const report = { prototype: pathToFileURL(prototypePath).href, checks: results.length, results };
    await fs.writeFile(path.join(evidenceDirectory, "interaction-checks.json"), `${JSON.stringify(report, null, 2)}\n`, "utf8");
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  } finally {
    await browser.close();
  }
}

main().catch(error => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exitCode = 1;
});
