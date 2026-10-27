// Cognito hosted-UI login with PKCE (D25). No client secret exists; the browser proves it started
// the login by presenting the verifier whose hash it sent first. Tokens live in sessionStorage
// (gone when the tab closes); the ID token is what the API's JWT authoriser checks.

import type { AppConfig } from "./model.js";

interface Tokens { id_token: string; access_token: string; refresh_token?: string; expires_at: number; }

const KEY = "sefs.tokens";
const VERIFIER = "sefs.pkce.verifier";

function b64url(bytes: ArrayBuffer): string {
  return btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export class Auth {
  constructor(private readonly cfg: AppConfig) {}

  private get redirect(): string { return `${location.origin}/`; }

  /** True when a usable (non-expired) ID token is at hand. */
  signedIn(): boolean {
    const t = this.tokens();
    return !!t && t.expires_at > Date.now() + 30_000;
  }

  idToken(): string {
    const t = this.tokens();
    if (!t) throw new Error("not signed in");
    return t.id_token;
  }

  private tokens(): Tokens | null {
    const raw = sessionStorage.getItem(KEY);
    return raw ? (JSON.parse(raw) as Tokens) : null;
  }

  /** Redirects to the hosted UI. Never returns on success. */
  async login(): Promise<void> {
    const verifierBytes = crypto.getRandomValues(new Uint8Array(32));
    const verifier = b64url(verifierBytes.buffer);
    sessionStorage.setItem(VERIFIER, verifier);
    const challenge = b64url(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)));
    const q = new URLSearchParams({
      response_type: "code", client_id: this.cfg.clientId, redirect_uri: this.redirect,
      scope: "openid email", code_challenge_method: "S256", code_challenge: challenge,
    });
    location.assign(`${this.cfg.cognitoDomain}/oauth2/authorize?${q}`);
  }

  /** If the URL carries ?code=…, exchange it for tokens and clean the URL. Returns true if it did. */
  async completeLogin(): Promise<boolean> {
    const code = new URLSearchParams(location.search).get("code");
    if (!code) return false;
    const verifier = sessionStorage.getItem(VERIFIER);
    if (!verifier) throw new Error("login state lost (no PKCE verifier in this tab); sign in again");
    const body = new URLSearchParams({
      grant_type: "authorization_code", client_id: this.cfg.clientId, code, redirect_uri: this.redirect, code_verifier: verifier,
    });
    const r = await fetch(`${this.cfg.cognitoDomain}/oauth2/token`, {
      method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body,
    });
    if (!r.ok) throw new Error(`token exchange failed: HTTP ${r.status}`);
    const j = await r.json() as { id_token: string; access_token: string; refresh_token?: string; expires_in: number };
    const t: Tokens = { id_token: j.id_token, access_token: j.access_token, refresh_token: j.refresh_token, expires_at: Date.now() + j.expires_in * 1000 };
    sessionStorage.setItem(KEY, JSON.stringify(t));
    sessionStorage.removeItem(VERIFIER);
    history.replaceState(null, "", this.redirect);
    return true;
  }

  /** Uses the refresh token once the ID token is about to expire; false when that is not possible. */
  async refresh(): Promise<boolean> {
    const t = this.tokens();
    if (!t?.refresh_token) return false;
    const body = new URLSearchParams({ grant_type: "refresh_token", client_id: this.cfg.clientId, refresh_token: t.refresh_token });
    const r = await fetch(`${this.cfg.cognitoDomain}/oauth2/token`, {
      method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body,
    });
    if (!r.ok) return false;
    const j = await r.json() as { id_token: string; access_token: string; expires_in: number };
    sessionStorage.setItem(KEY, JSON.stringify({ ...t, id_token: j.id_token, access_token: j.access_token, expires_at: Date.now() + j.expires_in * 1000 }));
    return true;
  }

  logout(): void {
    sessionStorage.removeItem(KEY);
    const q = new URLSearchParams({ client_id: this.cfg.clientId, logout_uri: this.redirect });
    location.assign(`${this.cfg.cognitoDomain}/logout?${q}`);
  }
}
