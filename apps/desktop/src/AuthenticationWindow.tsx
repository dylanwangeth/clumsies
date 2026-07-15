import { useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import type { NativeInvoke } from "@clumsies/api-client";
import { LoaderCircle, LogIn } from "lucide-react";
import clumsiesMark from "./assets/clumsies-mark.svg";
import { DesktopBackend } from "./backend";
import { WindowTitleBar } from "./window-title-bar";

type AuthenticationState =
  | { status: "idle" }
  | { status: "waiting" }
  | { status: "opening" }
  | { status: "failed"; message: string };

export function AuthenticationWindow() {
  const backendRef = useRef<DesktopBackend | null>(null);
  if (backendRef.current === null) {
    const nativeInvoke: NativeInvoke = <T,>(
      command: string,
      args?: Record<string, unknown>,
    ) => invoke<T>(command, args);
    backendRef.current = new DesktopBackend(nativeInvoke);
  }
  const [state, setState] = useState<AuthenticationState>({ status: "idle" });
  const pending = state.status === "waiting" || state.status === "opening";

  const authenticate = async () => {
    if (pending) {
      return;
    }
    setState({ status: "waiting" });
    try {
      const backend = backendRef.current;
      if (!backend) {
        throw new Error("Desktop authentication is unavailable");
      }
      await backend.authenticate();
      setState({ status: "opening" });
    } catch (error) {
      setState({
        status: "failed",
        message: error instanceof Error ? error.message : String(error),
      });
    }
  };

  return (
    <main className="authentication-shell">
      <WindowTitleBar className="authentication-title-bar" />
      <section className="authentication-content" aria-labelledby="authentication-title">
        <img className="authentication-logo" src={clumsiesMark} alt="" />
        <div className="authentication-heading">
          <h1 id="authentication-title">Sign in to Clumsies</h1>
          <p>Continue with your organization account.</p>
        </div>
        <form
          className="authentication-form"
          onSubmit={(event) => {
            event.preventDefault();
            void authenticate();
          }}
        >
          <button className="authentication-submit" disabled={pending} type="submit">
            {pending ? (
              <LoaderCircle aria-hidden="true" className="spin" size={16} />
            ) : (
              <LogIn aria-hidden="true" size={16} />
            )}
            {state.status === "waiting"
              ? "Waiting for browser"
              : state.status === "opening"
                ? "Opening workspace"
                : "Continue with SSO"}
          </button>
          <div className="authentication-feedback" aria-live="polite">
            {state.status === "failed" ? (
              <p className="authentication-error" role="alert">
                {state.message}
              </p>
            ) : null}
          </div>
        </form>
      </section>
    </main>
  );
}
