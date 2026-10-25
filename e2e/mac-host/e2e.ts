#!/usr/bin/env -S deno run --allow-run --allow-read --allow-write --allow-env
/**
 * mRemote の E2E テスト（Mac ホスト）。シミュレータの mRemote から、この Mac で動かした
 * テスト用の macos-rdp-server（127.0.0.1:3390）へつなぎ、接続・表示・入力・表示倍率・
 * 一覧からの開き直しを確かめる。
 *
 *   deno run -A e2e/mac-host/e2e.ts [--no-build] [--only 名前,名前] [--simulator <名前か UDID>]
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
const PROFILE = "E2E Mac";
const RESOLUTION = { w: 1920, h: 1080, label: "1920×1080（16:9）" };

const args = Deno.args;
const only = args.includes("--only") ? args[args.indexOf("--only") + 1].split(",") : null;
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
      TEST_RUNNER_MREMOTE_LIVE_HOLD: "900",
      TEST_RUNNER_MREMOTE_LIVE_COMMANDS: this.commands,
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
    const done = await waitFor(`「${line}」の完了`, async () => {
      const text = await Deno.readTextFile(`${this.commands}.done`).catch(() => "");
      return text.split("\n").find((l) => l.startsWith(`${n} `));
    }, timeoutMs).catch(async (e) => {
      const tail = (await Deno.readTextFile(`${RUN}/xctest.log`).catch(() => "")).split("\n").slice(-15).join("\n");
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

async function showTarget(): Promise<Frame> {
  await Deno.remove(TARGET_DIR, { recursive: true }).catch(() => {});
  target = new Deno.Command(TARGET, { args: [TARGET_DIR], stdout: "null", stderr: "null" }).spawn();
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

async function main() {
  await Deno.mkdir(RUN, { recursive: true });
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
    "run", "-A", `${SERVER}/tests/e2e/e2e.ts`, "--serve", "--keep", "120",
    // MREMOTE_E2E_SERVER_LOG=debug: サーバが受けたキーやポインタもログに出す
    ...(Deno.env.get("MREMOTE_E2E_SERVER_LOG") ? ["--log", Deno.env.get("MREMOTE_E2E_SERVER_LOG")!] : []),
  ])).trim());
  // 前の実行のプロファイルや設定を残さない
  await run("xcrun", ["simctl", "uninstall", sim, APP_ID], false);

  const app = new App();
  await app.start(sim);
  let frame: Frame | undefined;
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

    await test("reopen", "切断して一覧から開き直すと、同じ仮想ディスプレイで、初期倍率どおりに映る", async () => {
      expect(frame, "接続できていない");
      const before = await virtualDisplays();
      // 開き直す前に 100% にしておく（開き直したら初期倍率の「画面に合わせる」に戻るのが今の仕様）
      await withMenu(app, async () => {
        await app.cmd("reveal session-scale-picker");
        await app.cmd("tap session-scale-picker");
        expect((await app.cmd("button 100%")) === "ok", "表示倍率の 100% が選べない");
      });
      await press(app, "session-menu-button", "session-menu-close", true);
      expect((await app.cmd("reveal session-disconnect")) === "ok", "メニューに切断がない");
      await app.cmd("tap session-disconnect");
      expect((await app.cmd("button 切断")) === "ok", "切断の確認が出ない");
      expect((await app.cmd(`wait profile-row-${PROFILE} 15`)) === "ok", "一覧に戻らない");
      log("切断して一覧へ");
      await sleep(2000);
      await app.cmd(`tap profile-row-${PROFILE}`);
      expect((await app.cmd("connected 60", 120000)) === "ok", "開き直しても接続できない");
      log("開き直して接続");
      const after = await waitFor("仮想ディスプレイ", async () => {
        const v = await virtualDisplays();
        return v.length === 1 && v[0].pw === RESOLUTION.w && v;
      });
      expect(after[0].id === before[0]?.id, "仮想ディスプレイが使い回されていない", { before, after });
      frame = await targetFrame();
      const s = await waitFor("目印の窓が映る", async () => {
        const s = await shot(app, "reopen");
        try {
          expectFitted(s, frame!);
          return s;
        } catch (e) {
          log(`まだ: ${(e as Error).message.split("\n")[0]}`);
          return null;
        }
      }, 20000);
      expect((await scaleSetting(app)) === "画面に合わせる", "メニューの表示倍率が初期倍率と違う");
      return `ディスプレイ ${after[0].id}・デスクトップ ${s.background.w}x${s.background.h}px`;
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
