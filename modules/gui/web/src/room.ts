// A room: the internals of one family drawn as a floor with three low walls (the "doors" are open
// towards the camera) and one labelled box per item. The facts panel beside it lists everything
// the API returned, so nothing is hidden behind the picture.

import { COLOR, SceneView, TINT, type Pickable } from "./scene.js";
import type { Health, MapNode, Overview, Room, RoomKind } from "./model.js";

interface Item { id: string; label: string; health: Health; lines: [string, string][]; }

function rec(v: unknown): Record<string, unknown> { return (v && typeof v === "object") ? v as Record<string, unknown> : {}; }
function arr(v: unknown): Record<string, unknown>[] { return Array.isArray(v) ? v.map(rec) : []; }
function flat(o: Record<string, unknown>): [string, string][] {
  return Object.entries(o).filter(([, v]) => v !== null && v !== undefined && typeof v !== "object").map(([k, v]) => [k, String(v)]);
}

export class RoomScene extends SceneView {
  render(kind: RoomKind, room: Room, overview: Overview, factsEl: HTMLElement): void {
    this.clear();
    const items = this.items(kind, room, overview);
    const cols = Math.max(2, Math.ceil(Math.sqrt(items.length)));
    const rows = Math.max(1, Math.ceil(items.length / cols));
    const w = cols * 5 + 2, d = rows * 5 + 2;
    this.setView(Math.max(10, Math.max(w, d) * 0.75));
    this.plate(w, d, TINT.floor, 0, 0, -0.3, 0.3);
    this.box(w, 3, 0.4, TINT.wall, 0, -d / 2 - 0.2);            // back wall
    this.box(0.4, 3, d, TINT.wall, -w / 2 - 0.2, 0);            // left wall
    this.box(0.4, 3, d, TINT.wall, w / 2 + 0.2, 0);             // right wall
    items.forEach((it, i) => {
      const x = -w / 2 + 1 + 2.5 + (i % cols) * 5, z = -d / 2 + 1 + 2.5 + Math.floor(i / cols) * 5;
      const m = this.box(3.4, 1.8, 2.6, COLOR[it.health], x, z);
      const p: Pickable = { id: it.id, title: it.label, lines: it.lines };
      this.pick(m, p);
      this.label(it.label, x, 2.4, z);
    });
    this.facts(factsEl, kind, room, items);
  }

  private items(kind: RoomKind, room: Room, o: Overview): Item[] {
    const nodes = (k: MapNode["kind"]) => o.nodes.filter((n) => n.kind === k);
    const fromNode = (n: MapNode): Item => ({ id: n.id, label: `${n.label} · ${n.id}`, health: n.health, lines: [["health", `${n.health} ${n.reason}`], ...flat(n.facts)] });
    switch (kind) {
      case "efs": {
        const denied = room["readerWriteDenied"] === true;
        return [
          ...nodes("efs").map(fromNode),
          ...nodes("mount-target").map(fromNode),
          ...nodes("access-point").map(fromNode),
          { id: "policy", label: "file-system policy", health: denied ? "ok" : "down",
            lines: [["reader write denied", String(denied)], ["deny statements", String(room["denyStatements"] ?? 0)]] },
          { id: "lifecycle", label: "IA lifecycle", health: arr(room["lifecycle"]).length ? "ok" : "warn",
            lines: arr(room["lifecycle"]).flatMap((l) => flat(l)) },
        ];
      }
      case "ecs":
        return [
          ...nodes("cluster").map(fromNode),
          ...arr(room["services"]).map((s): Item => {
            const ro = s["readOnlyMount"] === true, role = String(s["role"]);
            return { id: String(s["name"]), label: `${role} service`, health: Number(s["running"]) >= Number(s["desired"]) ? "ok" : "down",
                     lines: [["mount flag", ro ? "read-only" : "read-write"], ["IAM auth", String(s["iamAuth"])], ["TLS", String(s["transitEncryption"])], ...flat(s)] };
          }),
          ...nodes("task").map(fromNode),
        ];
      case "vpc":
        return [
          ...nodes("vpc").map(fromNode),
          ...nodes("subnet-public").map(fromNode),
          ...nodes("subnet-private").map(fromNode),
          ...nodes("nat").map(fromNode),
          ...nodes("sg").map(fromNode),
          ...arr(room["routeTables"]).map((t): Item => ({
            id: String(t["id"]), label: `route table ${t["id"]}`, health: "ok",
            lines: [["subnets", arr(t["subnets"]).length ? (t["subnets"] as string[]).join(", ") : "main"],
                    ...arr(t["routes"]).map((r): [string, string] => [String(r["dest"]), String(r["via"] ?? "local")])] })),
          ...((room["internetGateways"] as string[] | undefined) ?? []).map((g): Item => ({ id: g, label: `internet gateway ${g}`, health: "ok", lines: [] })),
        ];
      case "backup":
        return [
          ...nodes("backup").map(fromNode),
          ...arr(room["jobs"]).map((j): Item => ({ id: String(j["id"]), label: `job ${String(j["state"]).toLowerCase()}`, health: j["state"] === "COMPLETED" ? "ok" : j["state"] === "FAILED" ? "down" : "warn", lines: flat(j) })),
          ...arr(room["recoveryPoints"]).map((p): Item => ({ id: String(p["arn"]), label: `recovery point ${String(p["created"]).slice(0, 10)}`, health: p["status"] === "COMPLETED" ? "ok" : "warn", lines: flat(p) })),
        ];
    }
  }

  private facts(el: HTMLElement, kind: RoomKind, room: Room, items: Item[]): void {
    el.replaceChildren();
    const h = document.createElement("h3"); h.textContent = `${kind} · read ${room.generatedAt}`; el.appendChild(h);
    for (const it of items) {
      const t = document.createElement("h3"); t.textContent = it.label; el.appendChild(t);
      for (const [k, v] of it.lines) {
        const row = document.createElement("div"); row.className = "fact";
        const a = document.createElement("span"); a.textContent = k;
        const b = document.createElement("span"); b.textContent = v;
        row.append(a, b); el.appendChild(row);
      }
    }
    if (kind === "efs") {
      const t = document.createElement("h3"); t.textContent = "policy (verbatim)"; el.appendChild(t);
      const pre = document.createElement("pre"); pre.textContent = JSON.stringify(room["policy"], null, 1); el.appendChild(pre);
    }
  }
}
