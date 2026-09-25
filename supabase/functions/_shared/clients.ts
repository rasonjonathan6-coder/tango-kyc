/**
 * Supabase clients.
 *
 * The service-role client bypasses RLS and is therefore only ever constructed
 * inside Edge Functions. It must never be handed to, or referenced by, the
 * Flutter application.
 */
import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2.58.0";
import { AppError } from "./http.ts";

export function env(name: string): string {
  return Deno.env.get(name) ?? "";
}

export function requireEnv(name: string): string {
  const value = env(name);
  if (!value) {
    console.error(`Missing required environment variable: ${name}`);
    throw new AppError("SERVICE_NOT_CONFIGURED", `${name} is not configured`, 503);
  }
  return value;
}

export function serviceClient(): SupabaseClient {
  return createClient(requireEnv("SUPABASE_URL"), requireEnv("SUPABASE_SERVICE_ROLE_KEY"), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/**
 * A client that acts *as the calling user*: the anon key plus the caller's own
 * access token. RLS applies and `auth.uid()` resolves, which is required for
 * functions such as `is_admin()` that gate on the current user.
 */
export function userClient(accessToken: string): SupabaseClient {
  return createClient(requireEnv("SUPABASE_URL"), requireEnv("SUPABASE_ANON_KEY"), {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });
}

export function bearerToken(req: Request): string {
  return (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
}

export interface AuthedUser {
  id: string;
  email: string | null;
  role: "user" | "admin";
  /** The caller's raw access token, for user-scoped Supabase clients. */
  token: string;
}

/**
 * Resolves the caller from the Authorization header. The access token is
 * verified against Supabase Auth; the admin role is read from the server-owned
 * profile row, never from client-supplied data.
 */
export async function requireUser(req: Request): Promise<AuthedUser> {
  const token = bearerToken(req);
  if (!token) {
    throw new AppError("AUTH_REQUIRED", "Missing bearer token", 401);
  }

  const admin = serviceClient();
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data?.user) {
    console.error("Token verification failed:", error?.message);
    throw new AppError("INVALID_TOKEN", "Invalid access token", 401);
  }

  const { data: profile } = await admin
    .from("profiles")
    .select("role")
    .eq("id", data.user.id)
    .maybeSingle();

  return {
    id: data.user.id,
    email: data.user.email ?? null,
    role: profile?.role === "admin" ? "admin" : "user",
    token,
  };
}

export async function requireAdmin(req: Request): Promise<AuthedUser> {
  const user = await requireUser(req);
  if (user.role !== "admin") {
    throw new AppError("FORBIDDEN", "Admin role required", 403);
  }
  return user;
}
