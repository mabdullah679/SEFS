// The HTML around the map: status pill, tooltip, cost panel, alarm list, log tail.

import type { CostReport, Health, LogTail, Overview } from "./model.js";
import type { Pickable } from "./scene.js";

const $ = <T extends HTMLElement>(id: string): T => {
  const el = document.getElementById(id);
  if (!el) throw new Error(`missing #${id}`);
  return el as T;
};

export class Hud {
  readonly overall = $("overall");
  readonly generated = $("generated");
  readonly tooltip = $("tooltip");
  readonly costBody = $("cost-body");
  readonly alarmList = $<HTMLUListElement>("alarm-list");
  readonly logBody = $<HTMLPreElement>("log-body");

  constructor(project: string) {
    $("project").textContent = project;
    $("gate-project").textContent = project;
  }

  status(o: Overview): void {
    this.overall.className = `pill ${o.overall}`;
    this.overall.textContent = o.deployed ? o.overall : "nothing deployed";
    this.generated.textContent = `read ${new Date(o.generatedAt).toLocaleTimeString()}`;
  }

  error(message: string): void {
    this.overall.className = "pill down";
    this.overall.textContent = "error";
    this.generated.textContent = message;
  }

  hover(p: Pickable | null, x: number, y: number): void {
    if (!p) { this.tooltip.hidden = true; return; }
    this.tooltip.replaceChildren();
    const b = document.createElement("b"); b.textContent = p.title; this.tooltip.appendChild(b);
    for (const [k, v] of p.lines) {
      const row = document.createElement("div");
      const key = document.createElement("span"); key.className = "k"; key.textContent = `${k}: `;
      row.append(key, document.createTextNode(v)); this.tooltip.appendChild(row);
    }
    if (p.onClick) { const c = document.createElement("div"); c.className = "k"; c.textContent = "click to open the doors"; this.tooltip.appendChild(c); }
    this.tooltip.hidden = false;
    this.tooltip.style.left = `${Math.min(x + 14, (this.tooltip.parentElement?.clientWidth ?? 9999) - 330)}px`;
    this.tooltip.style.top = `${y + 14}px`;
  }

  alarms(o: Overview): void {
    this.alarmList.replaceChildren();
    const alarms = o.nodes.filter((n) => n.kind === "alarm").sort((a, b) => a.label.localeCompare(b.label));
    if (!alarms.length) { const li = document.createElement("li"); li.className = "muted"; li.textContent = "none"; this.alarmList.appendChild(li); }
    for (const a of alarms) {
      const li = document.createElement("li");
      const dot = document.createElement("span"); dot.className = `dot ${a.health as Health}`;
      li.append(dot, document.createTextNode(`${a.label} · ${a.facts["state"] ?? ""}`));
      li.title = String(a.facts["reason"] ?? "");
      this.alarmList.appendChild(li);
    }
  }

  cost(c: CostReport): void {
    const usd = (n: number, p = 2) => `US$${n.toFixed(p)}`;
    const el = this.costBody; el.replaceChildren();
    const big = document.createElement("div"); big.className = "big"; big.textContent = `${usd(c.rates.perHour, 3)} / h`; el.appendChild(big);
    const sub = document.createElement("div"); sub.className = "muted";
    sub.textContent = `${usd(c.rates.perMinute, 4)} / min · ${usd(c.rates.per30Days)} / 30 d at today's rates`; el.appendChild(sub);
    const t = document.createElement("table");
    for (const it of c.rates.items) {
      const tr = t.insertRow(); tr.insertCell().textContent = it.item;
      const n = tr.insertCell(); n.className = "n"; n.textContent = usd(it.perHour, 4);
    }
    el.appendChild(t);
    const live = document.createElement("div"); live.className = "muted";
    live.textContent = `live: ${c.live.natGateways} NAT, ${c.live.vcpu} vCPU, ${c.live.memoryGb} GB, ${c.live.alarms} alarms · ${c.rates.source}`; el.appendChild(live);
    const a = c.actuals;
    const h = document.createElement("div"); h.style.marginTop = "8px";
    if (a === null) { h.className = "muted"; h.textContent = "real spend: off (cost_actuals = false)"; el.appendChild(h); return; }
    if ("error" in a) { h.className = "muted"; h.textContent = `real spend: not available (${a.error})`; el.appendChild(h); return; }
    h.innerHTML = ""; h.textContent = `real spend ${a.start} → ${a.end}: ${usd(a.totalUsd)} (Cost Explorer, Project tag)`; el.appendChild(h);
    const bars = document.createElement("div"); bars.className = "bars";
    const max = Math.max(0.01, ...a.days.map((d) => d.usd));
    for (const d of a.days) { const i = document.createElement("i"); i.style.height = `${Math.max(1, (d.usd / max) * 100)}%`; i.title = `${d.date}: ${usd(d.usd, 3)}`; bars.appendChild(i); }
    el.appendChild(bars);
  }

  costError(message: string): void { this.costBody.textContent = `cost: ${message}`; }

  logs(t: LogTail): void {
    this.logBody.className = "";
    this.logBody.textContent = t.lines.length
      ? t.lines.map((l) => `${new Date(l.ts).toISOString().slice(11, 19)} ${l.message}`).join("\n")
      : `no contract lines yet in ${t.group}`;
  }

  logsError(message: string): void { this.logBody.className = "muted"; this.logBody.textContent = message; }
}
