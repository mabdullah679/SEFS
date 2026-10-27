// The map: one plate per VPC, one column per AZ (public strip with its NAT on top, private strip
// with the tasks below), the EFS slab across the middle with a mount-target peg per AZ and the
// two access points on it, the backup vault at the side. Every box is coloured by live health.

import * as THREE from "three";
import { COLOR, SceneView, TINT, type Pickable } from "./scene.js";
import { roomFor, type MapNode, type Overview, type RoomKind } from "./model.js";

const AZ_W = 11, AZ_GAP = 2, STRIP_D = 7, EFS_D = 5;

export class OverviewScene extends SceneView {
  private onOpen: (kind: RoomKind, node: MapNode) => void = () => {};

  openRoom(fn: (kind: RoomKind, node: MapNode) => void): void { this.onOpen = fn; }

  private pickable(n: MapNode): Pickable {
    const lines: [string, string][] = [["health", `${n.health}${n.reason ? ` (${n.reason})` : ""}`]];
    if (n.az) lines.push(["az", n.az]);
    for (const [k, v] of Object.entries(n.facts)) if (v !== null && v !== undefined && typeof v !== "object") lines.push([k, String(v)]);
    const kind = roomFor(n.kind);
    return { id: n.id, title: `${n.label} · ${n.id}`, lines, onClick: kind ? () => this.onOpen(kind, n) : undefined };
  }

  render(o: Overview): void {
    this.clear();
    const by = (k: MapNode["kind"]) => o.nodes.filter((n) => n.kind === k);
    const azs = [...new Set(o.nodes.map((n) => n.az).filter((a): a is string => !!a))].sort();
    if (!o.deployed || azs.length === 0) {
      this.label(o.deployed ? "no AZ-scoped resources found" : `nothing deployed for ${o.name} in ${o.region}`, 0, 1, 0);
      return;
    }
    const total = azs.length * AZ_W + (azs.length - 1) * AZ_GAP;
    const x0 = -total / 2 + AZ_W / 2;
    this.setView(Math.max(16, total * 0.62));

    // VPC plate under everything
    const vpc = by("vpc")[0];
    const plate = this.plate(total + 6, STRIP_D * 2 + EFS_D + 8, TINT.plate, 0, 0, -0.4);
    if (vpc) { this.pick(plate, this.pickable(vpc)); this.label(`${vpc.label} · ${vpc.id}`, -total / 2 - 1, 0.6, -(STRIP_D + EFS_D / 2 + 3), true); }

    const pegAt = new Map<string, THREE.Vector3>();
    azs.forEach((az, i) => {
      const x = x0 + i * (AZ_W + AZ_GAP);
      const zPub = -(EFS_D / 2 + STRIP_D / 2 + 1), zPri = EFS_D / 2 + STRIP_D / 2 + 1;
      this.label(az, x, 0.9, zPub - STRIP_D / 2 - 0.8, true);
      const pub = by("subnet-public").find((s) => s.az === az);
      const pri = by("subnet-private").find((s) => s.az === az);
      const pubPlate = this.plate(AZ_W, STRIP_D, TINT.public, x, zPub);
      const priPlate = this.plate(AZ_W, STRIP_D, TINT.private, x, zPri);
      if (pub) { this.pick(pubPlate, this.pickable(pub)); this.label(pub.label, x - AZ_W / 2 + 2.2, 0.7, zPub + STRIP_D / 2 - 0.6, true); }
      if (pri) { this.pick(priPlate, this.pickable(pri)); this.label(pri.label, x - AZ_W / 2 + 2.2, 0.7, zPri + STRIP_D / 2 - 0.6, true); }
      // NAT in the public strip
      for (const nat of by("nat").filter((n) => n.az === az)) {
        const m = this.box(2.4, 2, 2.4, COLOR[nat.health], x, zPub - 1);
        this.pick(m, this.pickable(nat));
        this.label(`NAT ${nat.facts["publicIp"] ?? ""}`, x, 2.6, zPub - 1);
      }
      // tasks in the private strip, one per service role
      const tasks = by("task").filter((t) => t.az === az);
      tasks.forEach((t, j) => {
        const tx = x - 2.5 + j * 5;
        const m = this.box(3, 1.6, 2.4, COLOR[t.health], tx, zPri + 1);
        this.pick(m, this.pickable(t));
        this.label(`${t.label}`, tx, 2.2, zPri + 1);
        this.link(new THREE.Vector3(tx, 0.8, zPri + 1 - 1.2), new THREE.Vector3(x, 0.8, EFS_D / 2 + 0.3));
      });
      pegAt.set(az, new THREE.Vector3(x, 0.4, EFS_D / 2 + 0.3));
    });

    // EFS slab across the middle, mount target pegs per AZ, access points on top
    const efs = by("efs")[0];
    const slab = this.box(total + 2, 1.2, EFS_D, efs ? COLOR[efs.health] : TINT.slab, 0, 0);
    (slab.material as THREE.MeshLambertMaterial).color.lerp(new THREE.Color(TINT.slab), 0.55);
    if (efs) { this.pick(slab, this.pickable(efs)); this.label(`${efs.label} · ${efs.id}`, -total / 2 + 3, 1.9, 0); }
    for (const mt of by("mount-target")) {
      const at = mt.az ? pegAt.get(mt.az) : undefined;
      if (!at) continue;
      const m = this.box(1.2, 1.4, 1.2, COLOR[mt.health], at.x, at.z, 1.2 + 0.7);
      this.pick(m, this.pickable(mt));
      this.label(`mount ${mt.facts["ip"] ?? ""}`, at.x, 3.1, at.z, true);
    }
    by("access-point").forEach((ap, j) => {
      const ax = -3 + j * 6, az_ = -EFS_D / 2 + 1;
      const m = this.box(2.2, 1, 1.4, COLOR[ap.health], ax, az_, 1.2 + 0.5);
      this.pick(m, this.pickable(ap));
      this.label(`${ap.label} ${ap.facts["uid"] ?? ""}:${ap.facts["gid"] ?? ""}`, ax, 2.6, az_, true);
    });

    // security groups as thin rails: sg-apps along the private strip, sg-efs along the slab
    for (const sg of by("sg")) {
      const isEfs = sg.id === o.registry["efs_security_group_id"];
      const z = isEfs ? -EFS_D / 2 - 0.3 : EFS_D / 2 + STRIP_D + 1.6;
      const rail = this.box(total + 2, 0.3, 0.3, COLOR[sg.health], 0, z, 0.15);
      this.pick(rail, this.pickable(sg));
      this.label(`${sg.label}${isEfs ? " (2049 from sg-apps)" : ""}`, total / 2 - 3, 0.7, z, true);
    }

    // backup vault and cluster, beside the plate
    const bk = by("backup")[0];
    if (bk) {
      const m = this.box(3, 2.2, 3, COLOR[bk.health], total / 2 + 5.5, 0);
      this.pick(m, this.pickable(bk));
      this.label(`backup ${bk.facts["retentionDays"] ?? "?"} d · ${bk.facts["recoveryPoints"] ?? 0} points`, total / 2 + 5.5, 2.9, 0);
      this.link(new THREE.Vector3(total / 2 + 1, 0.6, 0), new THREE.Vector3(total / 2 + 4, 1, 0));
    }
    const cl = by("cluster")[0];
    if (cl) {
      const m = this.box(3, 1, 3, COLOR[cl.health], total / 2 + 5.5, EFS_D / 2 + STRIP_D / 2 + 1);
      this.pick(m, this.pickable(cl));
      this.label(cl.label, total / 2 + 5.5, 1.7, EFS_D / 2 + STRIP_D / 2 + 1);
    }
  }
}
