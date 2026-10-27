// Shared three.js plumbing: an isometric-leaning orthographic camera, a WebGL layer plus a CSS2D
// label layer, picking by raycast, and the health palette. Both the overview and the rooms extend it.
// Geometry is procedural (boxes, planes, lines): no model files (D24).

import * as THREE from "three";
import { CSS2DObject, CSS2DRenderer } from "three/addons/renderers/CSS2DRenderer.js";
import type { Health } from "./model.js";

export const COLOR: Record<Health, number> = { ok: 0x3fb950, warn: 0xd29922, down: 0xf85149, unknown: 0x6e7681 };
export const TINT = { plate: 0x1b2430, public: 0x24303d, private: 0x1f2a36, slab: 0x263a4d, wall: 0x2a3340, floor: 0x151b22 };

export interface Pickable { id: string; title: string; lines: [string, string][]; onClick?: () => void; }

export abstract class SceneView {
  protected readonly scene = new THREE.Scene();
  protected readonly camera: THREE.OrthographicCamera;
  protected readonly renderer: THREE.WebGLRenderer;
  protected readonly labels: CSS2DRenderer;
  protected readonly pickables = new Map<THREE.Object3D, Pickable>();
  private readonly ray = new THREE.Raycaster();
  private readonly mouse = new THREE.Vector2(-2, -2);
  private hovered: THREE.Object3D | null = null;
  private frame = 0;
  private extent = 20;

  constructor(protected readonly gl: HTMLElement, protected readonly labelLayer: HTMLElement, private readonly onHover: (p: Pickable | null, x: number, y: number) => void) {
    this.camera = new THREE.OrthographicCamera(-1, 1, 1, -1, 0.1, 500);
    this.renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
    this.renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
    gl.appendChild(this.renderer.domElement);
    this.labels = new CSS2DRenderer({ element: labelLayer });
    this.scene.add(new THREE.AmbientLight(0xffffff, 0.75));
    const sun = new THREE.DirectionalLight(0xffffff, 1.1);
    sun.position.set(30, 60, 20);
    this.scene.add(sun);
    this.setView(20);
    gl.addEventListener("pointermove", (e) => this.track(e));
    gl.addEventListener("pointerleave", () => { this.mouse.set(-2, -2); });
    gl.addEventListener("click", () => { const p = this.hovered ? this.pickables.get(this.hovered) : undefined; p?.onClick?.(); });
    new ResizeObserver(() => this.resize()).observe(gl);
    this.resize();
    this.loop();
  }

  /** 2.5D: looking down from the front-right at ~35°, orthographic so nothing shrinks with distance. */
  protected setView(extent: number): void {
    this.extent = extent;
    this.camera.position.set(extent * 0.9, extent * 1.4, extent * 1.2);
    this.camera.lookAt(0, 0, 0);
    this.resize();
  }

  private resize(): void {
    const w = this.gl.clientWidth || 1, h = this.gl.clientHeight || 1;
    const aspect = w / h, e = this.extent;
    this.camera.left = -e * aspect; this.camera.right = e * aspect; this.camera.top = e; this.camera.bottom = -e;
    this.camera.updateProjectionMatrix();
    this.renderer.setSize(w, h);
    this.labels.setSize(w, h);
  }

  private track(e: PointerEvent): void {
    const r = this.gl.getBoundingClientRect();
    this.mouse.set(((e.clientX - r.left) / r.width) * 2 - 1, -((e.clientY - r.top) / r.height) * 2 + 1);
    this.lastXY = [e.clientX - r.left, e.clientY - r.top];
  }
  private lastXY: [number, number] = [0, 0];

  private loop = (): void => {
    this.frame = requestAnimationFrame(this.loop);
    this.ray.setFromCamera(this.mouse, this.camera);
    const hit = this.ray.intersectObjects([...this.pickables.keys()], false)[0]?.object ?? null;
    if (hit !== this.hovered) {
      if (this.hovered) this.highlight(this.hovered, false);
      this.hovered = hit;
      if (hit) this.highlight(hit, true);
      this.gl.style.cursor = hit && this.pickables.get(hit)?.onClick ? "pointer" : "default";
      this.onHover(hit ? this.pickables.get(hit) ?? null : null, this.lastXY[0], this.lastXY[1]);
    }
    this.renderer.render(this.scene, this.camera);
    this.labels.render(this.scene, this.camera);
  };

  private highlight(o: THREE.Object3D, on: boolean): void {
    const m = (o as THREE.Mesh).material as THREE.MeshLambertMaterial | undefined;
    if (m?.emissive) m.emissive.setHex(on ? 0x334455 : 0x000000);
  }

  dispose(): void {
    cancelAnimationFrame(this.frame);
    this.renderer.dispose();
    this.gl.replaceChildren();
    this.labelLayer.replaceChildren();
  }

  /** Clears everything but the lights. */
  protected clear(): void {
    for (const o of [...this.scene.children]) if (!(o instanceof THREE.Light)) this.scene.remove(o);
    this.pickables.clear();
    this.hovered = null;
    this.labelLayer.replaceChildren();
  }

  // ---- builders
  protected box(w: number, h: number, d: number, color: number, x: number, z: number, y = h / 2): THREE.Mesh {
    const m = new THREE.Mesh(new THREE.BoxGeometry(w, h, d), new THREE.MeshLambertMaterial({ color }));
    m.position.set(x, y, z);
    this.scene.add(m);
    this.outline(m);
    return m;
  }

  protected plate(w: number, d: number, color: number, x: number, z: number, y = 0, h = 0.4): THREE.Mesh {
    return this.box(w, h, d, color, x, z, y + h / 2);
  }

  protected outline(mesh: THREE.Mesh): void {
    const edges = new THREE.LineSegments(new THREE.EdgesGeometry(mesh.geometry), new THREE.LineBasicMaterial({ color: 0x0b0f14, transparent: true, opacity: 0.6 }));
    mesh.add(edges);
  }

  protected label(text: string, x: number, y: number, z: number, dim = false): CSS2DObject {
    const el = document.createElement("div");
    el.className = dim ? "label dim" : "label";
    el.textContent = text;
    const o = new CSS2DObject(el);
    o.position.set(x, y, z);
    this.scene.add(o);
    return o;
  }

  protected link(a: THREE.Vector3, b: THREE.Vector3, color = 0x3d4a5c): void {
    const g = new THREE.BufferGeometry().setFromPoints([a, b]);
    this.scene.add(new THREE.Line(g, new THREE.LineBasicMaterial({ color })));
  }

  protected pick(mesh: THREE.Object3D, p: Pickable): void { this.pickables.set(mesh, p); }
}
