// Entry point. Config → login gate → one refresh loop that reads the overview, cost and logs,
// draws the map, and opens a room on click. Nothing here writes anywhere.

import { Api, ApiError } from "./api.js";
import { Auth } from "./auth.js";
import { Hud } from "./hud.js";
import { OverviewScene } from "./overview.js";
import { RoomScene } from "./room.js";
import type { AppConfig, MapNode, Overview, RoomKind } from "./model.js";

const el = (id: string): HTMLElement => {
  const e = document.getElementById(id);
  if (!e) throw new Error(`missing #${id}`);
  return e;
};

class App {
  private readonly hud: Hud;
  private readonly auth: Auth;
  private readonly api: Api;
  private readonly map: OverviewScene;
  private room: RoomScene | null = null;
  private latest: Overview | null = null;
  private logApp: "writer" | "reader" = "writer";
  private timer = 0;

  constructor(private readonly cfg: AppConfig) {
    this.hud = new Hud(cfg.name);
    this.auth = new Auth(cfg);
    this.api = new Api(cfg, this.auth);
    this.map = new OverviewScene(el("gl"), el("labels"), (p, x, y) => this.hud.hover(p, x, y));
    this.map.openRoom((kind, node) => void this.openRoom(kind, node));
    el("refresh").addEventListener("click", () => void this.refresh());
    el("logout").addEventListener("click", () => this.auth.logout());
    el("login").addEventListener("click", () => void this.auth.login());
    el("room-close").addEventListener("click", () => this.closeRoom());
    for (const b of document.querySelectorAll<HTMLButtonElement>("button.tab")) {
      b.addEventListener("click", () => {
        this.logApp = b.dataset["app"] as "writer" | "reader";
        document.querySelectorAll("button.tab").forEach((x) => x.classList.toggle("active", x === b));
        void this.loadLogs();
      });
    }
  }

  async start(): Promise<void> {
    try {
      await this.auth.completeLogin();
    } catch (e) {
      this.gate(String((e as Error).message));
      return;
    }
    if (!this.auth.signedIn() && !(await this.auth.refresh())) { this.gate(); return; }
    el("gate").hidden = true;
    el("logout").hidden = false;
    await this.refresh();
    this.timer = window.setInterval(() => void this.refresh(), Math.max(10, this.cfg.refreshSeconds) * 1000);
  }

  private gate(error?: string): void {
    el("gate").hidden = false;
    const ge = el("gate-error");
    ge.hidden = !error;
    ge.textContent = error ?? "";
  }

  private async refresh(): Promise<void> {
    try {
      const o = await this.api.overview();
      this.latest = o;
      this.hud.status(o);
      this.hud.alarms(o);
      this.map.render(o);
    } catch (e) {
      this.fail(e);
      return;
    }
    void Promise.allSettled([this.loadCost(), this.loadLogs()]);
  }

  private async loadCost(): Promise<void> {
    try { this.hud.cost(await this.api.cost()); } catch (e) { this.hud.costError((e as Error).message); }
  }

  private async loadLogs(): Promise<void> {
    try { this.hud.logs(await this.api.logs(this.logApp)); } catch (e) { this.hud.logsError((e as Error).message); }
  }

  private fail(e: unknown): void {
    if (e instanceof ApiError && e.status === 401) { window.clearInterval(this.timer); this.gate("session expired; sign in again"); return; }
    this.hud.error((e as Error).message);
  }

  private async openRoom(kind: RoomKind, node: MapNode): Promise<void> {
    if (!this.latest) return;
    el("room").hidden = false;
    el("room-title").textContent = `${node.label} · ${kind} internals`;
    el("room-facts").textContent = "reading…";
    this.room?.dispose();
    this.room = new RoomScene(el("room-gl"), el("room-labels"), (p, x, y) => this.hud.hover(p, x, y));
    try {
      const data = await this.api.room(kind);
      this.room.render(kind, data, this.latest, el("room-facts"));
    } catch (e) {
      el("room-facts").textContent = `could not read the ${kind} internals: ${(e as Error).message}`;
    }
  }

  private closeRoom(): void {
    el("room").hidden = true;
    this.room?.dispose();
    this.room = null;
    this.hud.hover(null, 0, 0);
  }
}

async function boot(): Promise<void> {
  const r = await fetch("config.json", { cache: "no-store" });
  if (!r.ok) throw new Error(`config.json: HTTP ${r.status}`);
  const cfg = (await r.json()) as AppConfig;
  await new App(cfg).start();
}

boot().catch((e: unknown) => {
  const gate = document.getElementById("gate"), err = document.getElementById("gate-error");
  if (gate) gate.hidden = false;
  if (err) { err.hidden = false; err.textContent = String((e as Error).message ?? e); }
});
