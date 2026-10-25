#!/usr/bin/env -S deno run --allow-run --allow-read --allow-write --allow-env
/**
 * mRemote の E2E テスト（Mac ホスト）。シミュレータの mRemote から、この Mac で動かした
 * テスト用の macos-rdp-server（127.0.0.1:3390）へつなぎ、接続・表示・入力・表示倍率・
 * 一覧からの開き直しを確かめる。
 *
 *   deno run -A e2e/mac-host/e2e.ts [--no-build] [--suite 組,組 | --only 名前,名前] [--simulator <名前か UDID>]
 *
 * 組（--suite。何も指定しなければ全部 = full、約 70 分）:
 *   smoke     接続・表示・タップ・キーボード・表示倍率の切り替え（普段はこれ。ビルド込みで 10 分ほど）
 *   settings  表示倍率・解像度・画質を覚えて次の接続に引き継ぐ（約 25 分）
 *   presets   解像度の候補（約 15 分）
 *   saver     無音のときの音声・省データ（約 15 分）
 *   full      全部
 * どの組も、最初に connect（接続先を作って接続する）を流す。
 *
 * 仕組み:
 * - サーバは macos-rdp-server（フォーク）の tests/e2e/e2e.ts --serve で、本番とは別に起動する
 *   （MACOS_RDP_SERVER でチェックアウトの場所を変えられる。既定 ~/projects/forks/macos-rdp-server）
 * - アプリは AppUITests/LiveRDPUITests の testConnectAndHold を、コマンドファイルで外から動かす
 * - Mac 側には目印の窓（e2e-target）を画面いっぱいに出す。決まった色の背景と四隅の色付きの四角、
 *   入力欄。アプリのスクリーンショットでどこまで見えているかを、窓の記録でクリックと文字を確かめる
 * - プロファイルは 1920×1080 固定で作る。iPhone の画面より大きいので、「画面に合わせる」なら
 *   四隅が全部見え、「100%」なら真ん中だけが見える
 */

const HOME = Deno.env.get("HOME")!;
const HERE = new URL(".", import.meta.url).pathname;
const REPO = new URL("../..", import.meta.url).pathname.replace(/\/$/, "");
const SERVER = Deno.env.get("MACOS_RDP_SERVER") ?? `${HOME}/projects/forks/macos-rdp-server`;
const WORK = "/tmp/mremote-e2e";
const RUN = `${WORK}/run`;
const DERIVED = `${WORK}/dd`;
const SERVER_WORK = "/tmp/rdp-e2e"; // サーバ側のツールの置き場（tests/e2e/e2e.ts と同じ）
const PROBE = `${SERVER_WORK}/display-probe`;
const TARGET = `${SERVER_WORK}/e2e-target`;
const TARGET_DIR = `${RUN}/target`;
const COLOR_BOXES = `${WORK}/color-boxes`;
const APP_ID = "com.mikuta0407.mRemote";
const RUNNER_ID = "com.mikuta0407.mRemoteUITests.xctrunner";
const PROFILE = "E2E Mac";
const RESOLUTION = { w: 1920, h: 1080, label: "1920×1080（16:9）" };
/** アプリが受け取った音声（AAC なら展開後）の書き出し先 */
const AUDIO_DUMP = `${RUN}/app-audio.raw`;
/** 「1」でモバイル回線・低データモード相当（Debug ビルドのアプリが 0.5 秒ごとに読む） */
const CONSTRAINT_FILE = `${RUN}/constrained`;
const { analyzeTone, writeToneWav, TONE_HZ, TONE_SECONDS } = await import(`file://${SERVER}/tests/e2e/tone.ts`);

const args = Deno.args;
/** 組ごとのテスト。並びはテストの書かれた順のまま流れる（前のテストの状態に頼るものがある） */
const SUITES: Record<string, string[]> = {
  smoke: ["display", "tap", "keyboard", "zoom-toggle"],
  settings: [
    "remember-menu", "remember-doubletap", "remember-settings", "remember-keep", "remember-relaunch",
    "remember-failed", "remember-duplicate", "remember-delete", "remember-upgrade", "settings-migrate",
    "writeback-resolution", "writeback-quality", "writeback-scale-editor", "writeback-inherit", "writeback-deleted",
  ],
  presets: ["presets-pickers", "preset-duo", "preset-portrait", "presets-nodisp"],
  saver: [
    "saver-silence", "saver-always", "saver-moving", "saver-never", "saver-auto", "saver-unscaled",
    "saver-switch-audio", "saver-nodisp",
  ],
};
function selectedTests(): string[] | null {
  if (args.includes("--only")) return args[args.indexOf("--only") + 1].split(",");
  if (!args.includes("--suite")) return null;
  const names = args[args.indexOf("--suite") + 1].split(",");
  if (names.includes("full")) return null;
  const unknown = names.filter((n) => !SUITES[n]);
  if (unknown.length) {
    console.error(`知らない組: ${unknown.join(", ")}（${Object.keys(SUITES).join("・")}・full）`);
    Deno.exit(2);
  }
  return ["connect", ...names.flatMap((n) => SUITES[n])];
}
const only = selectedTests();
const simulatorArg = args.includes("--simulator") ? args[args.indexOf("--simulator") + 1] : "iPhone Duo";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function run(cmd: string, argv: string[], check = true, cwd?: string): Promise<string> {
  const r = await new Deno.Command(cmd, { args: argv, cwd, stdout: "piped", stderr: "piped" }).output();
  const out = new TextDecoder().decode(r.stdout) + new TextDecoder().decode(r.stderr);
  if (check && r.code !== 0) throw new Error(`${cmd} ${argv.join(" ")} が失敗しました:\n${out.slice(-3000)}`);
  return out;
}

class Failure extends Error {}

function expect(ok: unknown, message: string, detail?: unknown): asserts ok {
  if (!ok) throw new Failure(`${message}${detail === undefined ? "" : `: ${JSON.stringify(detail)}`}`);
}

async function waitFor<T>(what: string, fn: () => Promise<T | null | undefined | false>, timeoutMs = 15000): Promise<T> {
  const end = Date.now() + timeoutMs;
  let last: unknown;
  while (Date.now() < end) {
    try {
      const v = await fn();
      if (v) return v as T;
      last = v;
    } catch (e) {
      last = e;
    }
    await sleep(300);
  }
  throw new Failure(`待ちきれませんでした: ${what}（最後: ${last instanceof Error ? last.message : JSON.stringify(last)}）`);
}

let started = Date.now();
const log = (s: string) => console.log(`  [${((Date.now() - started) / 1000).toFixed(1).padStart(5)}s] ${s}`);

// ── シミュレータとアプリ ─────────────────────────────────────────────

async function simulatorId(): Promise<string> {
  const list = JSON.parse(await run("xcrun", ["simctl", "list", "devices", "available", "-j"]));
  for (const devices of Object.values(list.devices) as { name: string; udid: string }[][]) {
    for (const d of devices) if (d.udid === simulatorArg || d.name === simulatorArg) return d.udid;
  }
  throw new Error(`シミュレータ ${simulatorArg} がありません`);
}

const xcodeArgs = (sim: string) => [
  "-project", `${REPO}/mRemote.xcodeproj`, "-scheme", "mRemote",
  "-destination", `platform=iOS Simulator,id=${sim}`, "-derivedDataPath", DERIVED,
  "-skipMacroValidation", "-skipPackagePluginValidation",
];

/** testConnectAndHold をコマンドファイルで動かす */
class App {
  private proc?: Deno.ChildProcess;
  private sent = 0;
  readonly commands = `${RUN}/commands.txt`;

  async start(sim: string) {
    await Deno.writeTextFile(this.commands, "");
    await Deno.remove(`${this.commands}.done`).catch(() => {});
    const env: Record<string, string> = {
      TEST_RUNNER_MREMOTE_LIVE_HOST: "127.0.0.1",
      TEST_RUNNER_MREMOTE_LIVE_PORT: "3390",
      TEST_RUNNER_MREMOTE_LIVE_USER: "e2e",
      TEST_RUNNER_MREMOTE_LIVE_PASSWORD: "e2e",
      TEST_RUNNER_MREMOTE_LIVE_PLATFORM: "macOS",
      TEST_RUNNER_MREMOTE_LIVE_PROFILE: PROFILE,
      TEST_RUNNER_MREMOTE_LIVE_RESOLUTION: RESOLUTION.label,
      TEST_RUNNER_MREMOTE_LIVE_HOLD: "5400", // 全部で 40 分ほどかかる
      TEST_RUNNER_MREMOTE_LIVE_COMMANDS: this.commands,
      // Debug ビルドだけの口: アプリが受け取った（展開後の）音声の書き出しと、回線の制約の模擬
      TEST_RUNNER_MREMOTE_APP_MREMOTE_AUDIO_DUMP_FILE: AUDIO_DUMP,
      TEST_RUNNER_MREMOTE_APP_MREMOTE_SIMULATED_CONSTRAINT_FILE: CONSTRAINT_FILE,
      // シミュレータの音は Mac から出て、テスト用サーバがまた拾って送り返す（こだまが止まらない）ので鳴らさない
      TEST_RUNNER_MREMOTE_APP_MREMOTE_MUTE_PLAYBACK: "1",
    };
    const logFile = await Deno.open(`${RUN}/xctest.log`, { create: true, write: true, truncate: true });
    this.proc = new Deno.Command("xcodebuild", {
      args: ["test-without-building", ...xcodeArgs(sim), "-only-testing:mRemoteUITests/LiveRDPUITests/testConnectAndHold"],
      env, stdout: "piped", stderr: "piped",
    }).spawn();
    this.proc.stdout.pipeTo(logFile.writable).catch(() => {});
    this.proc.stderr.pipeTo((await Deno.open(`${RUN}/xctest.err.log`, { create: true, write: true, truncate: true })).writable)
      .catch(() => {});
  }

  /** 1 行送って、終わるのを待つ。結果（"ok"・"value=..." など）を返す */
  async cmd(line: string, timeoutMs = 30000): Promise<string> {
    await Deno.writeTextFile(this.commands, line + "\n", { append: true });
    const n = ++this.sent;
    const finished = async () => {
      const text = await Deno.readTextFile(`${this.commands}.done`).catch(() => "");
      return text.split("\n").find((l) => l.startsWith(`${n} `));
    };
    const done = await waitFor(`「${line}」の完了`, finished, timeoutMs).catch(async (e) => {
      const tail = (await Deno.readTextFile(`${RUN}/xctest.log`).catch(() => "")).split("\n").slice(-15).join("\n");
      // アプリ側はまだこの命令を実行している（XCTest が「アプリが落ち着くまで」60 秒ずつ待つことがある）。
      // ここで先へ進むと、次のテストの命令がこの後ろに並んで足並みがずれ、残りが全部失敗する。終わるまで待つ
      await waitFor(`「${line}」が遅れて終わるの`, finished, 300000).catch(() => {});
      throw new Failure(`${(e as Error).message}\n--- xctest.log の最後 ---\n${tail}`);
    });
    // "<番号> <結果> <コマンド>"
    return done.slice(`${n} `.length, done.length - line.length).trim();
  }

  async end() {
    if (!this.proc) return;
    await Deno.writeTextFile(this.commands, "end\n", { append: true }).catch(() => {});
    const finished = await Promise.race([this.proc.status.then(() => true), sleep(60000).then(() => false)]);
    if (!finished) this.proc.kill("SIGTERM");
  }

  get status() {
    return this.proc?.status;
  }
}

// ── Mac 側: 目印の窓・画面 ─────────────────────────────────────────────

interface Frame {
  display: number;
  x: number;
  y: number;
  w: number;
  h: number;
  scale: number;
}

let target: Deno.ChildProcess | undefined;
/** 目印の窓が覆っている範囲（いま映っているはずの Mac の画面） */
let frame: Frame | undefined;

async function showTarget(animate = false): Promise<Frame> {
  hideTarget();
  await Deno.remove(TARGET_DIR, { recursive: true }).catch(() => {});
  target = new Deno.Command(TARGET, {
    args: animate ? [TARGET_DIR, "--animate"] : [TARGET_DIR], stdout: "null", stderr: "null",
  }).spawn();
  return await targetFrame();
}

async function targetFrame(): Promise<Frame> {
  return await waitFor("目印の窓", async () => JSON.parse(await Deno.readTextFile(`${TARGET_DIR}/frame.json`)));
}

function hideTarget() {
  try {
    target?.kill("SIGTERM");
  } catch { /* 終わっている */ }
  target = undefined;
}

async function clicks(): Promise<{ x: number; y: number }[]> {
  const text = await Deno.readTextFile(`${TARGET_DIR}/clicks.txt`).catch(() => "");
  return text.trim().split("\n").filter(Boolean).map((l) => {
    const [, x, y] = l.split(" ");
    return { x: Number(x), y: Number(y) };
  });
}

/**
 * 入力欄にキーが届く状態にする: 入力欄（Mac の画面の真ん中）をタップしてクリックし、目印の窓のアプリが前面で
 * 入力欄が編集中になったことを確かめる。通知の確認パネルなどが前面を取っていると届かない
 */
async function focusField(app: App) {
  await app.cmd("tapat remote-desktop-surface 0.5 0.5");
  const status = await waitFor("目印の窓の入力欄が前面", async () => {
    const s = JSON.parse(await Deno.readTextFile(`${TARGET_DIR}/status.json`));
    return s.active && s.key && s.editing && s;
  }, 5000).catch(async () => {
    const s = await Deno.readTextFile(`${TARGET_DIR}/status.json`).catch(() => "{}");
    throw new Failure(`Mac 側で目印の窓の入力欄が前面にない（キーが届かない状態）: ${s.trim()}`);
  });
  return status;
}

async function typed(): Promise<string> {
  return await Deno.readTextFile(`${TARGET_DIR}/typed.txt`).catch(() => "");
}

interface Display {
  id: number;
  main: boolean;
  w: number;
  h: number;
  pw: number;
  ph: number;
  hidpi: boolean;
  vendor: number;
}

async function virtualDisplays(): Promise<Display[]> {
  const probe = JSON.parse(await run(PROBE, []));
  return probe.displays.filter((d: Display) => d.vendor === 0x5244500);
}

// ── アプリの画面を調べる ─────────────────────────────────────────────

interface Box {
  count: number;
  x: number;
  y: number;
  w: number;
  h: number;
}
interface Shot {
  path: string;
  scale: number;
  width: number;
  height: number;
  background: Box;
  topLeft: Box;
  topRight: Box;
  bottomLeft: Box;
  bottomRight: Box;
}

let shots = 0;

async function shot(app: App, name: string): Promise<Shot> {
  const path = `${RUN}/shot-${String(++shots).padStart(2, "0")}-${name}.png`;
  const result = await app.cmd(`shot ${path}`);
  const scale = Number(result.match(/scale=([\d.]+)/)?.[1] ?? 0);
  expect(scale > 0, "スクリーンショットが撮れない", result);
  return { path, scale, ...JSON.parse(await run(COLOR_BOXES, [path])) };
}

const CORNERS = ["topLeft", "topRight", "bottomLeft", "bottomRight"] as const;

/** 目印の窓の四隅のうち、ちゃんと映っているもの（四角の大きさの半分以上の画素がある） */
function visibleCorners(s: Shot, expectedCornerPixels: number): string[] {
  return CORNERS.filter((c) => s[c].count > expectedCornerPixels * 0.5);
}

/** 「画面に合わせる」で映っていること: 四隅が全部見え、正しい位置にあり、縦横比が Mac の画面と同じ */
function expectFitted(s: Shot, frame: Frame) {
  const bg = s.background;
  expect(bg.count > 1000, "目印の窓が映っていない", s);
  const aspect = bg.w / bg.h, want = frame.w / frame.h;
  expect(Math.abs(aspect / want - 1) < 0.03, "映っているデスクトップの縦横比が Mac の画面と違う", { aspect, want, bg });
  const side = Math.min(bg.w, bg.h) * 0.15;
  const corners = visibleCorners(s, side * side);
  expect(corners.length === 4, "四隅が全部は見えていない（画面に合わせていない）", { corners, shot: s.path });
  const near = (a: number, b: number) => Math.abs(a - b) <= Math.max(6, bg.w * 0.02);
  expect(near(s.topLeft.x, bg.x) && near(s.topLeft.y, bg.y), "左上の目印の位置が違う", s.topLeft);
  expect(near(s.topRight.x + s.topRight.w, bg.x + bg.w) && near(s.topRight.y, bg.y), "右上の目印の位置が違う", s.topRight);
  expect(near(s.bottomLeft.x, bg.x) && near(s.bottomLeft.y + s.bottomLeft.h, bg.y + bg.h), "左下の目印の位置が違う", s.bottomLeft);
  expect(
    near(s.bottomRight.x + s.bottomRight.w, bg.x + bg.w) && near(s.bottomRight.y + s.bottomRight.h, bg.y + bg.h),
    "右下の目印の位置が違う", s.bottomRight,
  );
}

/** 「100%」で映っていること: デスクトップ 1 画素が 1 ポイント。iPhone より大きいので四隅は見えず、背景が画面いっぱい */
function expectOneToOne(s: Shot) {
  const corners = CORNERS.filter((c) => s[c].count > 2000);
  expect(corners.length === 0, "四隅が見えている（100% になっていない）", { corners, shot: s.path });
  expect(s.background.w > s.width * 0.8, "背景が画面いっぱいに広がっていない", { bg: s.background, shot: s.path });
}

async function surfaceFrame(app: App): Promise<{ x: number; y: number; w: number; h: number }> {
  const result = await app.cmd("frame remote-desktop-surface");
  const m = result.match(/frame=\(([-\d.]+), ([-\d.]+), ([-\d.]+), ([-\d.]+)\)/);
  expect(m, "デスクトップの面の位置がわからない", result);
  return { x: Number(m[1]), y: Number(m[2]), w: Number(m[3]), h: Number(m[4]) };
}

/**
 * 浮いているボタンを、印（check）が望む状態になるまで押す。ボタンはしばらく触らないと端に寄り、
 * そのときの最初のタップは起こすだけになる
 */
async function press(app: App, button: string, check: string, wantExists: boolean) {
  for (let i = 0; i < 3; i++) {
    await app.cmd(`tap ${button}`);
    const r = await app.cmd(`${wantExists ? "wait" : "waitgone"} ${check} 3`);
    if (r === "ok") return;
  }
  throw new Failure(`${button} を押しても ${check} が${wantExists ? "出ない" : "消えない"}`);
}

/** セッションのメニューを開いて body を実行し、必ず閉じる */
async function withMenu<T>(app: App, body: () => Promise<T>): Promise<T> {
  await press(app, "session-menu-button", "session-menu-close", true);
  try {
    return await body();
  } finally {
    if ((await app.cmd("exists session-menu-close")) === "exists=true") {
      await app.cmd("tap session-menu-close");
      await app.cmd("waitgone session-menu-close 5");
    }
  }
}

async function setTouchMode(app: App, label: string) {
  await withMenu(app, async () => {
    expect((await app.cmd("reveal session-touch-mode-picker")) === "ok", "メニューに画面のタッチがない");
    await app.cmd("tap session-touch-mode-picker");
    expect((await app.cmd(`button ${label}`)) === "ok", `「${label}」が選べない`);
  });
}

async function scaleSetting(app: App): Promise<string> {
  return await withMenu(app, async () => {
    expect((await app.cmd("reveal session-scale-picker")) === "ok", "メニューに表示倍率がない");
    const value = await app.cmd("value session-scale-picker");
    // Picker の値は label に「表示倍率、画面に合わせる」の形で入る
    return value.match(/label=表示倍率、(.+)$/)?.[1] ?? value;
  });
}

// ── 変更定義書のテストのための手順 ──────────────────────────────────

async function startServer(extra: string[] = []) {
  // テストの正弦波を Mac のスピーカーから鳴らさない
  await run("deno", [
    "run", "-A", `${SERVER}/tests/e2e/e2e.ts`, "--serve", "--keep", "120", "--env", "RDP_AUDIO_LOCAL=0", ...extra,
  ]);
}

async function stopServer() {
  hideTarget();
  await run("deno", ["run", "-A", `${SERVER}/tests/e2e/e2e.ts`, "--stop"], false);
}

/** 一覧の接続先を開き、画面が出るまで待つ。目印の窓がなければ出す */
async function openProfile(app: App, name: string) {
  expect((await app.cmd(`wait profile-row-${name} 15`)) === "ok", `一覧に ${name} がない`);
  await app.cmd(`tap profile-row-${name}`);
  expect((await app.cmd("connected 60", 120000)) === "ok", `${name} に接続できない`);
  log(`${name} を開いた`);
  if (!target) await showTarget();
}

/** 一覧の「実行中」から、維持していたセッションへ戻る */
async function openRunning(app: App, name: string) {
  expect((await app.cmd(`wait running-session-${name} 10`)) === "ok", `実行中に ${name} がない`);
  await app.cmd(`tap running-session-${name}`);
  expect((await app.cmd("wait remote-desktop-surface 15")) === "ok", "セッションに戻れない");
}

async function disconnectToList(app: App) {
  await press(app, "session-menu-button", "session-menu-close", true);
  expect((await app.cmd("reveal session-disconnect")) === "ok", "メニューに切断がない");
  await app.cmd("tap session-disconnect");
  expect((await app.cmd("button 切断")) === "ok", "切断の確認が出ない");
  expect((await app.cmd("wait profile-list 15")) === "ok", "一覧に戻らない");
  await sleep(1500);
}

async function returnToList(app: App) {
  await withMenu(app, async () => {
    expect((await app.cmd("reveal session-return-to-list")) === "ok", "メニューに一覧へ戻るがない");
    await app.cmd("tap session-return-to-list");
  });
  expect((await app.cmd("wait profile-list 10")) === "ok", "一覧に戻らない");
}

async function setScale(app: App, label: "100%" | "画面に合わせる") {
  await withMenu(app, async () => {
    await app.cmd("reveal session-scale-picker");
    await app.cmd("tap session-scale-picker");
    expect((await app.cmd(`button ${label}`)) === "ok", `表示倍率の ${label} が選べない`);
  });
}

/** 画面の映り方とメニューの表示倍率の両方が label であること */
async function expectScale(app: App, label: "100%" | "画面に合わせる", name: string): Promise<Shot | undefined> {
  frame = await targetFrame();
  const s = await waitFor(`${label} で映る`, async () => {
    const f = await targetFrame();
    const s = await shot(app, name);
    try {
      if (label === "100%") expectOneToOne(s);
      else expectFitted(s, f);
      return s;
    } catch (e) {
      log(`まだ: ${(e as Error).message.split("\n")[0]}`);
      return null;
    }
  }, 20000);
  const menu = await scaleSetting(app);
  expect(menu === label, `メニューの表示倍率が「${menu}」（${label} のはず）`);
  return s;
}

/** Mac の仮想ディスプレイがこの画素数になり、目印の窓が覆い直すまで待つ */
async function expectDisplay(pw: number, ph: number): Promise<Display> {
  const d = await waitFor(`仮想ディスプレイ ${pw}x${ph}`, async () => {
    const v = await virtualDisplays();
    return v.length === 1 && v[0].pw === pw && v[0].ph === ph && v[0];
  }, 20000);
  frame = await waitFor("目印の窓が覆い直す", async () => {
    const f = await targetFrame();
    return Math.round(f.w * f.scale) === pw && f;
  }, 10000);
  return d;
}

/** 映っているデスクトップの (u, v) の割合の所をタップし、Mac の同じ所がクリックされたことを確かめる */
async function tapAt(app: App, s: Shot, u: number, v: number): Promise<string> {
  const f = await targetFrame();
  const surface = await surfaceFrame(app);
  const bg = s.background;
  const before = (await clicks()).length;
  const px = (bg.x + bg.w * u) / s.scale, py = (bg.y + bg.h * v) / s.scale;
  await app.cmd(`tapat remote-desktop-surface ${((px - surface.x) / surface.w).toFixed(4)} ${((py - surface.y) / surface.h).toFixed(4)}`);
  const click = await waitFor("クリック", async () => (await clicks())[before]);
  const want = { x: f.x + f.w * u, y: f.y + f.h * v };
  expect(Math.abs(click.x - want.x) <= f.w * 0.02 && Math.abs(click.y - want.y) <= f.w * 0.02,
    "クリックの位置がずれている", { want, got: click });
  return `(${click.x.toFixed(0)},${click.y.toFixed(0)})`;
}

// ── 通信量・音声・設定の道具（docs/changes/2026-10-25-data-saver.md・-session-settings-writeback.md）──

/** シミュレータの mRemote が seconds 秒に受け取った量（kbps） */
async function appKbps(seconds: number): Promise<number> {
  const pid = (await run("pgrep", ["-f", "mRemote.app/mRemote$"], false)).trim().split("\n")[0];
  expect(pid, "mRemote が動いていない");
  const bytes = async () => {
    const out = await run("nettop", ["-P", "-L", "1", "-p", pid, "-x"], false);
    const [header, row] = out.trim().split("\n");
    const column = header.split(",").indexOf("bytes_in");
    return Number(row?.split(",")[column] ?? 0);
  };
  const a = await bytes();
  await sleep(seconds * 1000);
  const b = await bytes();
  return ((b - a) * 8) / 1000 / seconds;
}

async function setConstrained(on: boolean) {
  await Deno.writeTextFile(CONSTRAINT_FILE, on ? "1" : "0");
  await sleep(1500); // アプリは 0.5 秒ごとに読む
}

/** Mac で正弦波を鳴らし、アプリが受け取った音（展開後）を調べる */
async function playToneAndCheck(name: string) {
  const wav = `${RUN}/tone.wav`;
  await writeToneWav(wav);
  const before = (await Deno.stat(AUDIO_DUMP).catch(() => ({ size: 0 }))).size;
  await run("afplay", [wav]);
  await sleep(1500);
  const all = await Deno.readFile(AUDIO_DUMP);
  const [rate, channels] = (await Deno.readTextFile(`${AUDIO_DUMP}.format`)).trim().split(" ").map(Number);
  const start = before - (before % (2 * channels));
  const report = analyzeTone(all.subarray(start), rate, channels);
  log(`${name}: ${JSON.stringify(report)}`);
  expect(report.seconds > TONE_SECONDS - 0.5, `${name}: 音が短い（欠けた）`, report);
  expect(Math.abs(report.frequency - TONE_HZ) < TONE_HZ * 0.005, `${name}: 周波数がずれている`, report);
  expect(report.snrDb > 25 && report.dropouts === 0, `${name}: 音が崩れている`, report);
  return report;
}

async function setDataSaver(app: App, label: "自動（モバイル回線・低データモードで有効）" | "常に" | "使わない") {
  await withMenu(app, async () => {
    expect((await app.cmd("reveal session-data-saver-picker")) === "ok", "メニューに省データがない");
    await app.cmd("tap session-data-saver-picker");
    expect((await app.cmd(`choose ${label}`)) === "ok", `省データの ${label} が選べない`);
  });
}

async function dataSaverStatus(app: App): Promise<string> {
  return await withMenu(app, async () => {
    await app.cmd("reveal session-data-saver-status");
    return (await app.cmd("value session-data-saver-status")).replace(/^value=\S* label=/, "");
  });
}

/** 接続先の編集画面を開いて、ピッカーの値を読む（取り消して閉じる） */
async function editorValues(app: App, name: string, ids: string[]): Promise<Record<string, string>> {
  await app.cmd(`hold profile-row-${name} 1.5`);
  expect((await app.cmd("button 編集")) === "ok", "編集がない");
  const values: Record<string, string> = {};
  for (const id of ids) {
    expect((await app.cmd(`reveal ${id}`)) === "ok", `編集画面に ${id} がない`);
    values[id] = (await app.cmd(`value ${id}`)).replace(/^value=\S* label=[^、]*、/, "");
  }
  await app.cmd("tap profile-cancel-button");
  await app.cmd("wait profile-list 5");
  return values;
}

async function setMenuPicker(app: App, id: string, label: string) {
  await withMenu(app, async () => {
    expect((await app.cmd(`reveal ${id}`)) === "ok", `メニューに ${id} がない`);
    await app.cmd(`tap ${id}`);
    expect((await app.cmd(`choose ${label}`)) === "ok", `${label} が選べない`);
  });
}

// ── テスト ────────────────────────────────────────────────────────────

interface Result {
  name: string;
  ok: boolean;
  detail: string;
  ms: number;
}
const results: Result[] = [];

async function test(name: string, title: string, body: () => Promise<string | void>) {
  if (only && !only.includes(name)) return;
  console.log(`▶ ${name}: ${title}`);
  const t0 = started = Date.now();
  try {
    const detail = (await body()) ?? "";
    results.push({ name, ok: true, detail, ms: Date.now() - t0 });
    console.log(`✅ ${name} ${detail}`);
  } catch (e) {
    const detail = e instanceof Failure ? e.message : `${(e as Error).stack ?? e}`;
    results.push({ name, ok: false, detail, ms: Date.now() - t0 });
    console.log(`❌ ${name}\n${detail.replace(/^/gm, "   ")}`);
  }
}

async function productionInUse(): Promise<boolean> {
  const out = await run("netstat", ["-anp", "tcp"], false);
  return /\.3389\s+\S+\s+ESTABLISHED/.test(out);
}

async function main() {
  await Deno.mkdir(RUN, { recursive: true });
  // 本番のサーバ（3389）を使っている人がいると、テスト用の仮想ディスプレイがその人の画面からメインを奪う
  if (await productionInUse() && !args.includes("--force")) {
    console.error("本番のサーバ（3389）に接続中のクライアントがあります。切断してから実行してください（--force で無視）");
    Deno.exit(2);
  }
  const sim = await simulatorId();
  console.log(`準備: シミュレータ ${simulatorArg}（${sim}）`);
  await run("xcrun", ["simctl", "boot", sim], false);
  await run("xcrun", ["simctl", "bootstatus", sim, "-b"]);
  if (!args.includes("--no-build")) {
    console.log("準備: mRemote をテスト用にビルド");
    await run("xcodebuild", ["build-for-testing", ...xcodeArgs(sim), "-quiet"]);
  }
  await run("swiftc", ["-O", "-o", COLOR_BOXES, `${HERE}color-boxes.swift`]);
  console.log("準備: テスト用サーバを起動");
  console.log("  " + (await run("deno", [
    "run", "-A", `${SERVER}/tests/e2e/e2e.ts`, "--serve", "--keep", "120", "--env", "RDP_AUDIO_LOCAL=0",
    // MREMOTE_E2E_SERVER_LOG=debug: サーバが受けたキーやポインタもログに出す
    ...(Deno.env.get("MREMOTE_E2E_SERVER_LOG") ? ["--log", Deno.env.get("MREMOTE_E2E_SERVER_LOG")!] : []),
  ])).trim());
  // 前の実行が止まりきらずに残した UI テストのランナーは、同じコマンドファイルを読み続けるので止める
  await run("xcrun", ["simctl", "terminate", sim, RUNNER_ID], false);
  await run("xcrun", ["simctl", "terminate", sim, APP_ID], false);
  // 前の実行のプロファイルや設定を残さない
  await run("xcrun", ["simctl", "uninstall", sim, APP_ID], false);
  await Deno.remove(CONSTRAINT_FILE).catch(() => {});
  // アプリは最初の音で書き出し先を作り直す。前の実行の分が残っていると、その大きさから先を読んでしまう
  await Deno.remove(AUDIO_DUMP).catch(() => {});
  await Deno.remove(`${AUDIO_DUMP}.format`).catch(() => {});

  const app = new App();
  await app.start(sim);
  let surface: { x: number; y: number; w: number; h: number } | undefined;

  try {
    await test("connect", "プロファイルを作って接続し、Mac に仮想ディスプレイができる", async () => {
      // 最初のコマンドは、接続して画面が出てから実行される
      expect((await app.cmd("exists session-status", 240000)) === "exists=false", "接続中の表示が消えない");
      const vds = await waitFor("仮想ディスプレイ", async () => {
        const v = await virtualDisplays();
        return v.length === 1 && v[0].pw === RESOLUTION.w && v[0].ph === RESOLUTION.h && v;
      });
      expect(vds[0].main, "仮想ディスプレイがメインでない", vds[0]);
      frame = await showTarget();
      log(`目印の窓 ${JSON.stringify(frame)}`);
      return `${vds[0].pw}x${vds[0].ph}${vds[0].hidpi ? " Retina" : ""}（${vds[0].w}x${vds[0].h}pt）`;
    });

    await test("display", "Mac の画面が、画面に合わせて全部・正しい向きで映る", async () => {
      expect(frame, "接続できていない");
      const s = await waitFor("目印の窓が映る", async () => {
        const s = await shot(app, "fit");
        try {
          expectFitted(s, frame!);
          return s;
        } catch (e) {
          log(`まだ: ${(e as Error).message.split("\n")[0]}`);
          return null;
        }
      }, 20000);
      expect((await scaleSetting(app)) === "画面に合わせる", "メニューの表示倍率が「画面に合わせる」でない");
      return `デスクトップ ${s.background.w}x${s.background.h}px（画面 ${s.width}x${s.height}px）`;
    });

    await test("tap", "タップした所が Mac でクリックされる", async () => {
      expect(frame, "接続できていない");
      const s = await shot(app, "tap");
      surface = await surfaceFrame(app);
      const bg = s.background;
      const done: string[] = [];
      for (const [u, v] of [[0.25, 0.3], [0.75, 0.7], [0.5, 0.85]]) {
        const before = (await clicks()).length;
        // スクリーンショットの画素 → アプリのポイント → 面の中の割合
        const px = (bg.x + bg.w * u) / s.scale, py = (bg.y + bg.h * v) / s.scale;
        const fx = (px - surface.x) / surface.w, fy = (py - surface.y) / surface.h;
        await app.cmd(`tapat remote-desktop-surface ${fx.toFixed(4)} ${fy.toFixed(4)}`);
        const click = await waitFor("クリック", async () => (await clicks())[before]);
        const want = { x: frame.x + frame.w * u, y: frame.y + frame.h * v };
        const tolerance = frame.w * 0.02;
        expect(
          Math.abs(click.x - want.x) <= tolerance && Math.abs(click.y - want.y) <= tolerance,
          "クリックの位置がずれている", { want, got: click },
        );
        done.push(`(${click.x.toFixed(0)},${click.y.toFixed(0)})`);
        await sleep(600); // ダブルクリックと見なされないように
      }
      return done.join(" ");
    });

    await test("keyboard", "デッキのキーと iOS キーボードの文字が Mac に届く（デッキ → iOS → デッキ）", async () => {
      expect(frame, "接続できていない");
      // キーとして送る経路（文字ではなく Mac のキーコード）は、ラップトップデッキのキーで確かめる。
      // シミュレータでは XCTest が合成したハードウェアキーがアプリに届かない（入力診断で受信 0 件）ので使えない。
      // キーボードボタンは最後に使った方を出すので、どちらを出すかはメニューで選ぶ
      const showDeck = async () => {
        await withMenu(app, async () => {
          expect((await app.cmd("reveal session-toggle-laptop-deck")) === "ok", "メニューにデッキがない");
          await app.cmd("tap session-toggle-laptop-deck");
        });
        expect((await app.cmd("wait laptop-deck 5")) === "ok", "デッキが出ない");
      };
      const expectTyped = async (what: string, suffix: string) =>
        await waitFor(what, async () => {
          const t = await typed();
          return t.endsWith(suffix) && t;
        }, 10000).catch(async () => {
          throw new Failure(`${what}が届かない: 入力欄は ${JSON.stringify(await typed())}（${suffix} で終わるはず）`);
        });

      await focusField(app);
      await showDeck();
      for (const key of ["k", "q", "digit7"]) await app.cmd(`tap laptop-key-${key}`);
      await expectTyped("デッキのキー", "kq7");
      log("デッキ");

      await withMenu(app, async () => {
        expect((await app.cmd("reveal session-show-keyboard")) === "ok", "メニューにキーボードがない");
        await app.cmd("tap session-show-keyboard");
      });
      expect((await app.cmd("wait key-escape 5")) === "ok", "iOS キーボードが出ない");
      expect((await app.cmd("exists laptop-deck")) === "exists=false", "iOS キーボードとデッキが両方出ている");
      await app.cmd("type e2e");
      await expectTyped("iOS キーボードの文字", "kq7e2e");
      log("iOS キーボード");

      await showDeck();
      expect((await app.cmd("exists key-escape")) === "exists=false", "デッキと iOS キーボードが両方出ている");
      for (const key of ["z", "digit5"]) await app.cmd(`tap laptop-key-${key}`);
      const all = await expectTyped("iOS キーボードのあとのデッキのキー", "kq7e2ez5");
      await press(app, "session-keyboard-button", "laptop-deck", false); // しまう
      return `入力欄 ${JSON.stringify(all)}`;
    });

    await test("keyboard-hide", "iOS キーボードをボタンでしまってからデッキを出しても、デッキのキーが届く", async () => {
      expect(frame, "接続できていない");
      await focusField(app);
      const before = await typed();
      await withMenu(app, async () => {
        expect((await app.cmd("reveal session-show-keyboard")) === "ok", "メニューにキーボードがない");
        await app.cmd("tap session-show-keyboard");
      });
      expect((await app.cmd("wait key-escape 5")) === "ok", "iOS キーボードが出ない");
      await app.cmd("type x");
      await press(app, "session-keyboard-button", "key-escape", false);
      await withMenu(app, async () => {
        await app.cmd("reveal session-toggle-laptop-deck");
        await app.cmd("tap session-toggle-laptop-deck");
      });
      expect((await app.cmd("wait laptop-deck 5")) === "ok", "デッキが出ない");
      await app.cmd("tap laptop-key-y");
      const t = await waitFor("デッキのキー", async () => {
        const t = await typed();
        return t.endsWith("xy") && t;
      }, 10000).catch(async () => {
        throw new Failure(`届かない: 入力欄は ${JSON.stringify(await typed())}（前は ${JSON.stringify(before)}、xy で終わるはず）`);
      });
      await press(app, "session-keyboard-button", "laptop-deck", false);
      return `入力欄 ${JSON.stringify(t)}`;
    });

    await test("zoom-toggle", "ダブルタップで 100% にすると、メニューにも反映され、描き直しても 100% のまま", async () => {
      expect(frame, "接続できていない");
      // ダブルタップで倍率が変わるのは「画面のタッチ: 表示の移動だけ」のとき（ほかではダブルクリック）
      await setTouchMode(app, "表示の移動だけ");
      await app.cmd("doubletap remote-desktop-surface");
      await waitFor("100% で映る", async () => {
        try {
          expectOneToOne(await shot(app, "doubletap"));
          return true;
        } catch (e) {
          log(`まだ: ${(e as Error).message.split("\n")[0]}`);
          return false;
        }
      }, 8000);
      const setting = await scaleSetting(app);
      // メニューを開け閉めすると画面が描き直される。そのあとも 100% のまま
      const after = await shot(app, "after-menu");
      const errors: string[] = [];
      if (setting !== "100%") errors.push(`メニューの表示倍率が「${setting}」（100% のはず）`);
      try {
        expectOneToOne(after);
      } catch (e) {
        errors.push(`メニューを閉じたら 100% でなくなった: ${(e as Error).message}`);
      }
      expect(errors.length === 0, errors.join(" / "));
      // 元に戻す
      await app.cmd("doubletap remote-desktop-surface");
      await waitFor("画面に合わせる に戻る", async () => {
        try {
          expectFitted(await shot(app, "back-to-fit"), frame!);
          return true;
        } catch {
          return false;
        }
      }, 8000);
      await setTouchMode(app, "タッチした場所を操作");
      return "ダブルタップ → 100% → メニュー「100%」 → 描き直しても 100%";
    });

    // ── 表示倍率を接続先ごとに覚える（docs/changes/2026-10-25-remember-scale.md）──

    await test("remember-menu", "メニューで 100% にして切断し、一覧から開き直すと 100% で始まる", async () => {
      expect(frame, "接続できていない");
      const before = await virtualDisplays();
      await setScale(app, "100%");
      await disconnectToList(app);
      await openProfile(app, PROFILE);
      const after = await waitFor("仮想ディスプレイ", async () => {
        const v = await virtualDisplays();
        return v.length === 1 && v[0].pw === RESOLUTION.w && v;
      });
      expect(after[0].id === before[0]?.id, "仮想ディスプレイが使い回されていない", { before, after });
      await expectScale(app, "100%", "remember-menu");
      return `ディスプレイ ${after[0].id}・100% で始まった`;
    });

    await test("remember-doubletap", "ダブルタップで「画面に合わせる」に戻して開き直すと、画面に合わせるで始まる", async () => {
      await setTouchMode(app, "表示の移動だけ");
      await app.cmd("doubletap remote-desktop-surface");
      await expectScale(app, "画面に合わせる", "doubletap-fit");
      await setTouchMode(app, "タッチした場所を操作");
      await disconnectToList(app);
      await openProfile(app, PROFILE);
      await expectScale(app, "画面に合わせる", "remember-doubletap");
      return "ダブルタップの倍率も開き直しで引き継がれた";
    });

    await test("remember-settings", "設定の「表示」に「初期倍率」がない", async () => {
      await returnToList(app);
      await app.cmd("tap settings-button");
      expect((await app.cmd("wait settings-resolution-picker 5")) === "ok", "設定が開かない");
      const result = await app.cmd("haslabel 初期倍率");
      await app.cmd("back");
      expect(result === "haslabel=false", "設定に「初期倍率」が残っている", result);
      await openRunning(app, PROFILE);
      return "初期倍率なし";
    });

    await test("remember-keep", "「接続先一覧へ戻る（接続を維持）」から戻っても倍率はそのまま", async () => {
      await setScale(app, "100%");
      await returnToList(app);
      await openRunning(app, PROFILE);
      await expectScale(app, "100%", "remember-keep");
      return "100% のまま";
    });

    await test("remember-relaunch", "切断せずにアプリを終了し、起動し直して開くと最後の倍率で始まる", async () => {
      // 前のテストで 100%
      hideTarget();
      await app.cmd("terminate");
      expect((await app.cmd("launch", 60000)) === "ok", "アプリが起動しない");
      await openProfile(app, PROFILE);
      await expectScale(app, "100%", "remember-relaunch");
      return "起動し直しても 100%";
    });

    await test("remember-failed", "接続に失敗したあとでも、覚えた倍率は変わらない", async () => {
      await disconnectToList(app);
      await stopServer();
      await app.cmd(`tap profile-row-${PROFILE}`);
      expect((await app.cmd("wait session-retry 60", 90000)) === "ok", "接続の失敗が表示されない");
      log("接続に失敗");
      await withMenu(app, async () => {
        expect((await app.cmd("reveal session-disconnect")) === "ok", "メニューに切断がない");
        await app.cmd("tap session-disconnect");
        await app.cmd("button 切断");
      });
      expect((await app.cmd(`wait profile-row-${PROFILE} 15`)) === "ok", "一覧に戻らない");
      await startServer();
      await openProfile(app, PROFILE);
      await expectScale(app, "100%", "remember-failed");
      await expectDisplay(RESOLUTION.w, RESOLUTION.h);
      return "失敗のあとも 100%・解像度もそのまま";
    });

    await test("remember-duplicate", "複製は同じ倍率で始まり、複製先を変えても元は変わらない", async () => {
      const copy = `${PROFILE} のコピー`;
      await setScale(app, "100%");
      await disconnectToList(app);
      await app.cmd(`hold profile-row-${PROFILE} 1.5`);
      expect((await app.cmd("button 複製")) === "ok", "複製がない");
      expect((await app.cmd(`wait profile-row-${copy} 10`)) === "ok", "複製が一覧に出ない");
      await openProfile(app, copy);
      await expectScale(app, "100%", "duplicate");
      await setScale(app, "画面に合わせる");
      await disconnectToList(app);
      await openProfile(app, PROFILE);
      await expectScale(app, "100%", "original");
      await disconnectToList(app);
      await openProfile(app, copy);
      await expectScale(app, "画面に合わせる", "copy-again");
      return "複製は 100% で始まり、複製先は画面に合わせる・元は 100% のまま";
    });

    await test("remember-delete", "削除して同じ名前で作り直すと「画面に合わせる」で始まる", async () => {
      const copy = `${PROFILE} のコピー`;
      await setScale(app, "100%");
      await disconnectToList(app);
      await app.cmd(`hold profile-row-${copy} 1.5`);
      expect((await app.cmd("button 削除")) === "ok", "削除がない");
      expect((await app.cmd(`waitgone profile-row-${copy} 10`)) === "ok", "削除されない");
      expect((await app.cmd(`addprofile ${copy}|${RESOLUTION.label}`, 120000)) === "ok", "作り直せない");
      await openProfile(app, copy);
      await expectScale(app, "画面に合わせる", "recreated");
      await disconnectToList(app);
      return "作り直した接続先は画面に合わせる";
    });

    await test("remember-upgrade", "「初期倍率 100%」だった版から上げても、各接続先は最初「画面に合わせる」で始まる", async () => {
      // 前の版の状態を作る: 全体設定の初期倍率を 100% にし、覚えた倍率を消す
      hideTarget();
      await app.cmd("terminate");
      const sim = await simulatorId();
      const container = (await run("xcrun", ["simctl", "get_app_container", sim, APP_ID, "data"])).trim();
      const path = `${container}/Library/Application Support/mRemote-profiles.json`;
      const doc = JSON.parse(await Deno.readTextFile(path));
      doc.globalSettings.initialScale = "oneToOne";
      // 前の版は接続先に表示倍率を書かなかった
      for (const profile of doc.profiles) {
        const rdp = profile.configuration?.rdp?._0;
        if (rdp) rdp.initialScale = { inherit: {} };
      }
      await Deno.writeTextFile(path, JSON.stringify(doc));
      // アプリの設定はアプリのコンテナの中にある。cfprefsd を通して消す（ファイルを直接書くと古い値が戻る）
      const prefs = `${container}/Library/Preferences/${APP_ID}`;
      for (const profile of doc.profiles) {
        await run("xcrun", ["simctl", "spawn", sim, "defaults", "delete", prefs,
          `remembered-scale.${profile.id.rawValue}`], false);
      }
      const left = await run("xcrun", ["simctl", "spawn", sim, "defaults", "read", prefs], false);
      expect(!left.includes("remembered-scale"), "覚えた倍率を消せない", left);
      expect((await app.cmd("launch", 60000)) === "ok", "アプリが起動しない");
      await openProfile(app, PROFILE);
      await expectScale(app, "画面に合わせる", "upgrade");
      return "前の版の 100% の設定は使われない";
    });

    // ── メニューの設定を接続先に保存（docs/changes/2026-10-25-session-settings-writeback.md）──

    await test("settings-migrate", "前の版で端末に覚えていた表示倍率 100% は、接続先の設定に移って 100% で始まる", async () => {
      hideTarget();
      await app.cmd("terminate");
      const sim = await simulatorId();
      const container = (await run("xcrun", ["simctl", "get_app_container", sim, APP_ID, "data"])).trim();
      const path = `${container}/Library/Application Support/mRemote-profiles.json`;
      const doc = JSON.parse(await Deno.readTextFile(path));
      const profile = doc.profiles.find((p: { displayName: string }) => p.displayName === PROFILE);
      profile.configuration.rdp._0.initialScale = { inherit: {} };
      await Deno.writeTextFile(path, JSON.stringify(doc));
      const prefs = `${container}/Library/Preferences/${APP_ID}`;
      await run("xcrun", ["simctl", "spawn", sim, "defaults", "write", prefs,
        `remembered-scale.${profile.id.rawValue}`, "oneToOne"]);
      expect((await app.cmd("launch", 60000)) === "ok", "アプリが起動しない");
      const editor = await editorValues(app, PROFILE, ["profile-scale-picker"]);
      expect(editor["profile-scale-picker"] === "100%", "編集画面の表示倍率が 100% でない", editor);
      const left = await run("xcrun", ["simctl", "spawn", sim, "defaults", "read", prefs], false);
      expect(!left.includes("remembered-scale"), "端末の記憶が残っている", left);
      await openProfile(app, PROFILE);
      await expectScale(app, "100%", "migrate");
      return "移して 100%・端末の記憶は消えた";
    });

    await test("writeback-resolution", "メニューで変えた解像度で次も始まり、編集画面にも出る", async () => {
      await setMenuPicker(app, "session-resolution-picker", "2848×2004（iPhone Duo）");
      await expectDisplay(2848, 2004);
      await disconnectToList(app);
      const editor = await editorValues(app, PROFILE, ["profile-resolution-picker"]);
      expect(editor["profile-resolution-picker"] === "2848×2004（iPhone Duo）", "編集画面の解像度が違う", editor);
      await openProfile(app, PROFILE);
      await expectDisplay(2848, 2004);
      // 元に戻す（以降のテストは 1920×1080 の前提）
      await setMenuPicker(app, "session-resolution-picker", RESOLUTION.label);
      await expectDisplay(RESOLUTION.w, RESOLUTION.h);
      return "2848×2004 で始まり、編集画面も 2848×2004";
    });

    await test("writeback-quality", "メニューで変えた画質で次も始まり、編集画面にも出る", async () => {
      await setMenuPicker(app, "session-stream-quality", "低画質・省データ（15fps）");
      await disconnectToList(app);
      const editor = await editorValues(app, PROFILE, ["profile-stream-quality-picker"]);
      expect(editor["profile-stream-quality-picker"] === "低画質・省データ（15fps）", "編集画面の画質が違う", editor);
      await openProfile(app, PROFILE);
      const menu = await withMenu(app, async () => {
        await app.cmd("reveal session-stream-quality");
        return await app.cmd("value session-stream-quality");
      });
      expect(menu.includes("低画質・省データ（15fps）"), "メニューの画質が戻っている", menu);
      await setMenuPicker(app, "session-stream-quality", "自動（モバイル回線では低画質）");
      return "低画質で始まり、編集画面も低画質";
    });

    await test("writeback-scale-editor", "メニューの表示倍率は編集画面に出て、編集画面で変えると次の接続に効く", async () => {
      await setScale(app, "100%");
      await disconnectToList(app);
      let editor = await editorValues(app, PROFILE, ["profile-scale-picker"]);
      expect(editor["profile-scale-picker"] === "100%", "編集画面の表示倍率が 100% でない", editor);
      // 編集画面で「画面に合わせる」にして保存
      await app.cmd(`hold profile-row-${PROFILE} 1.5`);
      await app.cmd("button 編集");
      await app.cmd("reveal profile-scale-picker");
      await app.cmd("tap profile-scale-picker");
      expect((await app.cmd("choose 画面に合わせる")) === "ok", "画面に合わせるが選べない");
      await app.cmd("tap profile-save-button");
      await app.cmd("wait profile-list 10");
      editor = await editorValues(app, PROFILE, ["profile-scale-picker"]);
      expect(editor["profile-scale-picker"] === "画面に合わせる", "保存されていない", editor);
      await openProfile(app, PROFILE);
      await expectScale(app, "画面に合わせる", "editor-fit");
      return "編集画面で変えた倍率で始まった";
    });

    await test("writeback-inherit", "「全体設定に従う」だった解像度をメニューで変えると、その値になる", async () => {
      await disconnectToList(app);
      expect((await app.cmd("addprofile E2E 継承", 120000)) === "ok", "接続先を作れない");
      let editor = await editorValues(app, "E2E 継承", ["profile-resolution-picker"]);
      expect(editor["profile-resolution-picker"] === "全体設定に従う", "最初から全体設定に従うでない", editor);
      await openProfile(app, "E2E 継承");
      await setMenuPicker(app, "session-resolution-picker", "1600×1200（4:3）");
      await expectDisplay(1600, 1200);
      await disconnectToList(app);
      editor = await editorValues(app, "E2E 継承", ["profile-resolution-picker"]);
      expect(editor["profile-resolution-picker"] === "1600×1200（4:3）", "固定の値になっていない", editor);
      await openProfile(app, PROFILE);
      return "全体設定に従う → 1600×1200（4:3）";
    });

    await test("writeback-deleted", "開いている接続先を削除してから設定を変えても落ちず、何も残らない", async () => {
      await disconnectToList(app);
      await openProfile(app, "E2E 継承");
      await returnToList(app);
      await app.cmd("hold profile-row-E2E 継承 1.5");
      expect((await app.cmd("button 削除")) === "ok", "削除がない");
      expect((await app.cmd("waitgone profile-row-E2E 継承 10")) === "ok", "削除されない");
      await openRunning(app, "E2E 継承");
      await setScale(app, "100%");
      await setMenuPicker(app, "session-resolution-picker", "2048×1536（4:3）");
      await expectDisplay(2048, 1536);
      expect((await app.cmd("exists session-status")) === "exists=false", "接続が切れた");
      await disconnectToList(app);
      expect((await app.cmd("exists profile-row-E2E 継承")) === "exists=false", "削除した接続先が戻ってきた");
      await openProfile(app, PROFILE);
      return "落ちず、削除した接続先は戻らない";
    });

    // ── 解像度の候補（docs/changes/2026-10-25-resolution-presets.md）──

    await test("presets-pickers", "設定・接続先の編集・セッションのメニューの解像度が、横長・縦長の見出しつきで最後まで選べる", async () => {
      // 候補の数と並び順は単体テスト（DisplayScaleTests・ResolutionLabelTests）で確かめる。
      // ここでは、開いたメニューの上端に「横長」、下端に「縦長」の見出しがあり、最初と最後の候補まで届くこと
      const counts: string[] = [];
      // 開いたメニューを指でスクロールする（行は見えている分しか作られず、行ごとのスワイプは見失う）。
      // 窓の真ん中あたりを縦になぞる。toTop: 上端へ
      const scrollMenu = async (toTop: boolean) => {
        for (let i = 0; i < 4; i++) {
          await app.cmd(toTop ? "paths window 0.25 0.5 0.3 0.5 0.85" : "paths window 0.25 0.5 0.8 0.5 0.25");
        }
      };
      const check = async (where: string) => {
        await scrollMenu(true);
        const top = (await app.cmd("haslabel 横長")) === "haslabel=true" &&
          (await app.cmd("haslabel 1024×768（4:3）")) === "haslabel=true";
        // 少しずつ下へ: 途中で「縦長」の見出しが、最後に 2160×2880 が出る
        let portraitHeading = false, last = false;
        for (let i = 0; i < 10 && !last; i++) {
          await app.cmd("paths window 0.25 0.5 0.7 0.5 0.4");
          portraitHeading ||= (await app.cmd("haslabel 縦長")) === "haslabel=true";
          last = (await app.cmd("haslabel 2160×2880（3:4）")) === "haslabel=true";
        }
        const bottom = portraitHeading && last;
        expect(top && bottom, `${where}の見出しか端の候補が出ない`, { top, portraitHeading, last });
        counts.push(where);
      };
      // セッションのメニュー: いちばん下の縦長まで選べ、Mac がその大きさになる
      await withMenu(app, async () => {
        expect((await app.cmd("reveal session-resolution-picker")) === "ok", "メニューに解像度がない");
        await app.cmd("tap session-resolution-picker");
        await check("メニュー");
        expect((await app.cmd("choose 2160×2880（3:4）")) === "ok", "最後の候補が選べない");
      });
      await expectDisplay(2160, 2880);
      await withMenu(app, async () => {
        await app.cmd("reveal session-resolution-picker");
        await app.cmd("tap session-resolution-picker");
        expect((await app.cmd("choose 2048×1536（4:3）")) === "ok", "2048×1536 が選べない");
      });
      await expectDisplay(2048, 1536);
      await returnToList(app);
      // 設定
      await app.cmd("tap settings-button");
      await app.cmd("reveal settings-resolution-picker");
      await app.cmd("tap settings-resolution-picker");
      await check("設定");
      await scrollMenu(true);
      expect((await app.cmd("choose 自動（画面に合わせる）")) === "ok", "設定の自動が選べない"); // 今の値を選び直して閉じる
      await app.cmd("back");
      // 接続先の編集（以前の候補 3840×2160 を選んである接続先）
      expect((await app.cmd(`addprofile E2E 4K|3840×2160（16:9）`, 120000)) === "ok", "4K の接続先を作れない");
      await app.cmd("hold profile-row-E2E 4K 1.5");
      await app.cmd("button 編集");
      expect((await app.cmd("reveal profile-resolution-picker")) === "ok", "編集画面に解像度がない");
      const value = await app.cmd("value profile-resolution-picker");
      expect(value.includes("3840×2160（16:9）"), "以前の候補が選ばれていない", value);
      await app.cmd("tap profile-resolution-picker");
      await check("編集");
      await app.cmd("choose 2160×2880（3:4）"); // 閉じるため。編集は取り消すので保存されない
      await app.cmd("tap profile-cancel-button");
      await openRunning(app, PROFILE);
      return `見出しあり（${counts.join("・")}）・最後の候補と 2048×1536 に切り替わった`;
    });

    await test("preset-duo", "2848×2004（iPhone Duo）でつなぐと、Mac が Retina の 2848×2004 になり四隅まで映る", async () => {
      await disconnectToList(app);
      expect((await app.cmd("addprofile E2E Duo|2848×2004（iPhone Duo）", 120000)) === "ok", "接続先を作れない");
      await openProfile(app, "E2E Duo");
      const d = await expectDisplay(2848, 2004);
      expect(d.hidpi, "Retina になっていない", d);
      await expectScale(app, "画面に合わせる", "duo");
      return `${d.pw}x${d.ph}（${d.w}x${d.h}pt）`;
    });

    await test("preset-portrait", "1352×1920（iPhone Duo 縦）でつなぐと Retina の縦長になり、横にしてもタップがずれない", async () => {
      await disconnectToList(app);
      expect((await app.cmd("addprofile E2E 縦|1352×1920（iPhone Duo 縦）", 120000)) === "ok", "接続先を作れない");
      await openProfile(app, "E2E 縦");
      const d = await expectDisplay(1352, 1920);
      expect(d.hidpi, "Retina になっていない", d);
      await expectScale(app, "画面に合わせる", "portrait");
      await app.cmd("orient left");
      await app.cmd("sleep 2");
      const s = await expectScale(app, "画面に合わせる", "portrait-landscape");
      const click = await tapAt(app, s!, 0.3, 0.7);
      await app.cmd("orient portrait");
      await app.cmd("sleep 2");
      return `${d.pw}x${d.ph}（${d.w}x${d.h}pt）・横向きのタップ ${click}`;
    });

    await test("presets-nodisp", "表示制御チャネルのないサーバでは、候補を選んでも大きさが変わらず落ちない", async () => {
      await disconnectToList(app);
      await stopServer();
      await startServer(["--env", "RDP_DISP=0"]);
      await openProfile(app, "E2E Duo");
      await expectDisplay(2848, 2004);
      await withMenu(app, async () => {
        await app.cmd("reveal session-resolution-picker");
        expect((await app.cmd("haslabel このサーバーは接続中の解像度変更に対応していません")) === "haslabel=true",
          "対応していないことの説明がない");
      });
      await app.cmd("sleep 3");
      await expectDisplay(2848, 2004);
      expect((await app.cmd("exists session-status")) === "exists=false", "接続が切れた");
      await disconnectToList(app);
      await stopServer();
      await startServer();
      return "2848×2004 のまま・説明あり";
    });

    // ── 省データ（docs/changes/2026-10-25-data-saver.md）──

    await test("saver-silence", "音が止まったら受信量が戻り、次の音は欠けずに届く（無音は送らない）", async () => {
      await disconnectToList(app);
      expect((await app.cmd("addprofile E2E 省データ|2848×2004（iPhone Duo）", 120000)) === "ok", "接続先を作れない");
      await openProfile(app, "E2E 省データ");
      await setDataSaver(app, "使わない");
      await expectDisplay(2848, 2004);
      await playToneAndCheck("1 回目");
      await sleep(3000);
      const kbps = await appKbps(15);
      log(`音が止まったあとの静止画面: ${kbps.toFixed(0)}kbps`);
      expect(kbps < 150, "無音なのに音声が流れている", { kbps });
      await playToneAndCheck("止まったあとの音");
      return `静止 ${kbps.toFixed(0)}kbps・次の音も欠けない`;
    });

    await test("saver-always", "省データ「常に」: 音声は AAC で少なく、Mac は等倍で映りタップも合う", async () => {
      await setDataSaver(app, "常に");
      const d = await expectDisplay(1424, 1002);
      expect(!d.hidpi && d.w === 1424, "等倍の 1424×1002 になっていない", d);
      await expectScale(app, "画面に合わせる", "saver-fit");
      const s = await shot(app, "saver-tap");
      const click = await tapAt(app, s, 0.3, 0.6);
      expect((await dataSaverStatus(app)).startsWith("有効です"), "メニューで有効と出ていない");
      // 音声込みの受信量
      const wav = `${RUN}/tone.wav`;
      await writeToneWav(wav);
      const measuring = appKbps(4);
      await run("afplay", [wav]);
      const kbps = await measuring;
      log(`省データで音を鳴らしている間: ${kbps.toFixed(0)}kbps`);
      expect(kbps < 300, "音声込みの受信量が多い", { kbps });
      await playToneAndCheck("AAC の音");
      return `1424×1002 等倍・タップ ${click}・音声込み ${kbps.toFixed(0)}kbps`;
    });

    await test("saver-moving", "省データ「常に」では、動きのある画面の受信量が「使わない」の半分未満", async () => {
      frame = await showTarget(true);
      await sleep(3000);
      const saving = await appKbps(15);
      await setDataSaver(app, "使わない");
      await expectDisplay(2848, 2004);
      await showTarget(true);
      await sleep(3000);
      const full = await appKbps(15);
      log(`動きのある画面: 省データ ${saving.toFixed(0)}kbps・使わない ${full.toFixed(0)}kbps`);
      frame = await showTarget();
      expect(saving < full / 2, "半分未満になっていない", { saving, full });
      return `省データ ${saving.toFixed(0)}kbps・使わない ${full.toFixed(0)}kbps`;
    });

    await test("saver-never", "「使わない」に戻すと Retina の 2848×2004 と非圧縮の音声に戻り、編集画面にも出る", async () => {
      const d = await expectDisplay(2848, 2004);
      expect(d.hidpi, "Retina に戻っていない", d);
      const wav = `${RUN}/tone.wav`;
      await writeToneWav(wav);
      const measuring = appKbps(4);
      await run("afplay", [wav]);
      const kbps = await measuring;
      log(`使わないで音を鳴らしている間: ${kbps.toFixed(0)}kbps`);
      expect(kbps > 1000, "音声が非圧縮に戻っていない", { kbps });
      await playToneAndCheck("非圧縮の音");
      await disconnectToList(app);
      const editor = await editorValues(app, "E2E 省データ", ["profile-data-saver-picker"]);
      expect(editor["profile-data-saver-picker"] === "使わない", "編集画面の省データが違う", editor);
      await openProfile(app, "E2E 省データ");
      return `2848×2004 Retina・音声 ${kbps.toFixed(0)}kbps・編集画面も使わない`;
    });

    await test("saver-auto", "省データ「自動」: 回線の制約が付くと、つないだまま有効になり、外れると戻る", async () => {
      await setConstrained(false);
      await setDataSaver(app, "自動（モバイル回線・低データモードで有効）");
      await expectDisplay(2848, 2004);
      expect((await dataSaverStatus(app)).startsWith("いまは無効"), "Wi-Fi 相当で無効と出ていない");
      await setConstrained(true);
      await expectDisplay(1424, 1002);
      expect((await dataSaverStatus(app)).startsWith("いまは有効"), "制約ありで有効と出ていない");
      await playToneAndCheck("自動で有効の音");
      await setConstrained(false);
      await expectDisplay(2848, 2004);
      expect((await app.cmd("exists session-status")) === "exists=false", "接続が切れた");
      return "制約あり 1424×1002 → なし 2848×2004";
    });

    await test("saver-unscaled", "拡大率 100% で頼んでいる画面は、省データでも大きさが変わらない", async () => {
      await setMenuPicker(app, "session-remote-scale-picker", "100%");
      await expectDisplay(2848, 2004);
      await setDataSaver(app, "常に");
      await sleep(3000);
      const d = await expectDisplay(2848, 2004);
      expect(!d.hidpi, "拡大率 100% なのに Retina", d);
      await setMenuPicker(app, "session-remote-scale-picker", "自動（端末に合わせる）");
      await expectDisplay(1424, 1002);
      return "拡大率 100% では 2848×2004 のまま";
    });

    await test("saver-switch-audio", "音を鳴らしたまま省データを切り替えても、落ちず音が続く", async () => {
      const wav = `${RUN}/long-tone.wav`;
      await writeToneWav(wav);
      const playing = (async () => {
        for (let i = 0; i < 3; i++) await run("afplay", [wav]);
      })();
      await sleep(2000);
      await setDataSaver(app, "使わない");
      await sleep(2000);
      await setDataSaver(app, "常に");
      await playing;
      expect((await app.cmd("exists session-status")) === "exists=false", "接続が切れた");
      await playToneAndCheck("切り替えたあとの音");
      await setDataSaver(app, "自動（モバイル回線・低データモードで有効）");
      return "切り替え中も落ちず、そのあとの音も崩れない";
    });

    await test("saver-nodisp", "表示制御チャネルのないサーバでは、省データでも画面の大きさが変わらず落ちない", async () => {
      await disconnectToList(app);
      await stopServer();
      await startServer(["--env", "RDP_DISP=0"]);
      await openProfile(app, "E2E 省データ");
      await expectDisplay(2848, 2004);
      await setDataSaver(app, "常に");
      await sleep(4000);
      await expectDisplay(2848, 2004);
      expect((await app.cmd("exists session-status")) === "exists=false", "接続が切れた");
      await setDataSaver(app, "自動（モバイル回線・低データモードで有効）");
      await disconnectToList(app);
      await stopServer();
      await startServer();
      return "2848×2004 のまま";
    });
  } finally {
    await app.end();
    hideTarget();
    console.log("後片付け: テスト用サーバを止める");
    await run("deno", ["run", "-A", `${SERVER}/tests/e2e/e2e.ts`, "--stop"], false);
  }

  console.log("\n結果");
  for (const r of results) {
    console.log(`${r.ok ? "✅" : "❌"} ${r.name.padEnd(12)} ${(r.ms / 1000).toFixed(1)}s ${r.ok ? r.detail : r.detail.split("\n")[0]}`);
  }
  await Deno.writeTextFile(`${RUN}/results.json`, JSON.stringify(results, null, 2));
  console.log(`スクリーンショットとログ: ${RUN}`);
  Deno.exit(results.length > 0 && results.every((r) => r.ok) ? 0 : 1);
}

try {
  await main();
} catch (e) {
  console.error(e);
  hideTarget();
  await run("deno", ["run", "-A", `${SERVER}/tests/e2e/e2e.ts`, "--stop"], false);
  Deno.exit(1);
}
