// The data contract with modules/gui/api/app.py. Field names are the API's; keep them in sync.

export type Health = "ok" | "warn" | "down" | "unknown";

export type NodeKind =
  | "vpc" | "subnet-public" | "subnet-private" | "nat" | "sg"
  | "efs" | "mount-target" | "access-point"
  | "cluster" | "service" | "task"
  | "backup" | "alarm";

export interface MapNode {
  id: string;
  kind: NodeKind;
  label: string;
  az: string | null;
  parent: string | null;
  health: Health;
  reason: string;
  facts: Record<string, unknown>;
}

export interface Overview {
  name: string;
  region: string;
  generatedAt: string;
  deployed: boolean;
  overall: Health;
  nodes: MapNode[];
  registry: Record<string, string>;
}

export interface RateItem { item: string; perHour: number; }
export interface Rates { items: RateItem[]; perHour: number; perMinute: number; per30Days: number; region: string; source: string; fetchedAt?: string; }
export interface Actuals { start: string; end: string; days: { date: string; usd: number }[]; totalUsd: number; }
export interface CostReport {
  rates: Rates | null;                 // null with a `note` when nothing is metered (the local Docker stack)
  actuals: Actuals | { error: string } | null;
  live: { natGateways: number; vcpu: number; memoryGb: number; alarms: number; tasks?: number };
  note?: string;
}

export interface LogLine { ts: number; message: string; }
export interface LogTail { app: "writer" | "reader"; group: string; stream: string | null; lines: LogLine[]; }

export type RoomKind = "efs" | "ecs" | "vpc" | "backup";
export interface Room { kind: RoomKind; generatedAt: string; [k: string]: unknown; }

export interface AppConfig {
  name: string;
  region: string;
  account: string;
  userPoolId: string;
  clientId: string;
  cognitoDomain: string;
  apiUrl: string;
  refreshSeconds: number;
  /** true only when served by modules/gui/dev/local.py: no Cognito, the API is a local stand-in */
  local?: boolean;
}

/** Which room a click on a node opens. */
export function roomFor(kind: NodeKind): RoomKind | null {
  switch (kind) {
    case "efs": case "mount-target": case "access-point": return "efs";
    case "cluster": case "service": case "task": return "ecs";
    case "vpc": case "subnet-public": case "subnet-private": case "nat": case "sg": return "vpc";
    case "backup": return "backup";
    default: return null;
  }
}
