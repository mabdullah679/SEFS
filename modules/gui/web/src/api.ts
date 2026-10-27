// Typed GET-only client for the read-only data API. Every request carries the Cognito ID token.

import type { Auth } from "./auth.js";
import type { AppConfig, CostReport, LogTail, Overview, Room, RoomKind } from "./model.js";

export class ApiError extends Error {
  constructor(message: string, readonly status: number) { super(message); }
}

export class Api {
  constructor(private readonly cfg: AppConfig, private readonly auth: Auth) {}

  private async get<T>(path: string): Promise<T> {
    if (!this.auth.signedIn() && !(await this.auth.refresh())) throw new ApiError("session expired", 401);
    const r = await fetch(`${this.cfg.apiUrl}${path}`, { headers: { authorization: `Bearer ${this.auth.idToken()}` } });
    const text = await r.text();
    let body: unknown = null;
    try { body = JSON.parse(text); } catch { /* non-JSON error page */ }
    if (!r.ok) {
      const msg = (body as { error?: string } | null)?.error ?? text.slice(0, 200) ?? r.statusText;
      throw new ApiError(`${path}: ${msg}`, r.status);
    }
    return body as T;
  }

  overview(): Promise<Overview> { return this.get<Overview>("/api/overview"); }
  cost(): Promise<CostReport> { return this.get<CostReport>("/api/cost"); }
  room(kind: RoomKind): Promise<Room> { return this.get<Room>(`/api/room/${kind}`); }
  logs(app: "writer" | "reader", limit = 30): Promise<LogTail> { return this.get<LogTail>(`/api/logs?app=${app}&limit=${limit}`); }
}
