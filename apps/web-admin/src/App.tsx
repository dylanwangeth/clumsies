import { useEffect, useMemo, useState, type FormEvent } from "react";
import {
  ClumsiesApiError,
  ClumsiesAdminApi,
  createAdminApiClient,
  type AdminSchema,
} from "@clumsies/api-client";
import {
  ArrowRight,
  Check,
  CircleAlert,
  KeyRound,
  LoaderCircle,
  ShieldCheck,
} from "lucide-react";
import {
  parseEmailDomains,
  resolveSetupStage,
  validateSetupForm,
  type SetupForm,
  type SetupFormErrors,
} from "./setup-model";
import { AdminApp } from "./admin/AdminApp";

type SetupStatus = AdminSchema<"SetupStatus">;
type WebAdminSession = AdminSchema<"WebAdminSession">;

const DEFAULT_FORM: SetupForm = {
  orgName: "Clumsies Lab",
  projectName: "Default",
  domains: "",
};

export function App() {
  const serverUrl = useMemo(resolveServerUrl, []);
  const api = useMemo(
    () =>
      new ClumsiesAdminApi(
        createAdminApiClient({
          baseUrl: serverUrl,
          credentials: "include",
        }),
      ),
    [serverUrl],
  );
  const [bootstrap, setBootstrap] = useState<
    | { state: "loading" }
    | { state: "setup"; status: SetupStatus }
    | { state: "login"; notice: string | null }
    | { state: "admin"; session: WebAdminSession }
    | { state: "error"; message: string }
  >({ state: "loading" });

  useEffect(() => {
    let active = true;
    async function load() {
      try {
        const status = await api.setup();
        if (!active) return;
        if (status.state === "setup_required") {
          setBootstrap({ state: "setup", status });
          return;
        }
        try {
          const session = await api.session();
          if (active) setBootstrap({ state: "admin", session });
        } catch (error) {
          if (!active) return;
          if (error instanceof ClumsiesApiError && error.status === 401) {
            setBootstrap({ state: "login", notice: loginNotice() });
          } else {
            throw error;
          }
        }
      } catch (error) {
        if (active) {
          setBootstrap({ state: "error", message: errorMessage(error) });
        }
      }
    }
    void load();
    return () => {
      active = false;
    };
  }, [api]);

  if (bootstrap.state === "loading") {
    return <AppLoading />;
  }
  if (bootstrap.state === "error") {
    return <FatalState message={bootstrap.message} />;
  }
  if (bootstrap.state === "setup") {
    return (
      <SetupApp
        api={api}
        initialStatus={bootstrap.status}
        serverUrl={serverUrl}
      />
    );
  }
  if (bootstrap.state === "login") {
    return <LoginScreen notice={bootstrap.notice} serverUrl={serverUrl} />;
  }
  return (
    <AdminApp
      initialSession={bootstrap.session}
      onSessionEnded={(notice) => {
        window.history.replaceState(null, "", "/admin");
        setBootstrap({ state: "login", notice });
      }}
      serverUrl={serverUrl}
    />
  );
}

function SetupApp({
  api,
  initialStatus,
  serverUrl,
}: {
  api: ClumsiesAdminApi;
  initialStatus: SetupStatus;
  serverUrl: string;
}) {
  const [status, setStatus] = useState<SetupStatus | null>(initialStatus);
  const [csrfToken, setCsrfToken] = useState<string | null>(null);
  const [setupCode, setSetupCode] = useState("");
  const [form, setForm] = useState<SetupForm>(DEFAULT_FORM);
  const [errors, setErrors] = useState<SetupFormErrors>({});
  const [notice, setNotice] = useState<string | null>(callbackError());
  const [busy, setBusy] = useState(false);
  const stage = resolveSetupStage(status, csrfToken);

  useEffect(() => {
    const configuration = initialStatus.session?.configuration;
    if (configuration) {
      setForm({
        orgName: configuration.org_name,
        projectName: configuration.default_project_name,
        domains: configuration.allowed_email_domains.join(", "),
      });
    }
  }, [initialStatus]);

  async function claimSetup(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setBusy(true);
    setNotice(null);
    try {
      const session = await api.createSetupSession(setupCode);
      setCsrfToken(session.csrf_token);
      setSetupCode("");
      setStatus(await api.setup());
    } catch (error) {
      setNotice(errorMessage(error));
    } finally {
      setBusy(false);
    }
  }

  async function configureAndClaimOwner(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const nextErrors = validateSetupForm(form);
    setErrors(nextErrors);
    if (Object.keys(nextErrors).length > 0 || !csrfToken) return;
    setBusy(true);
    setNotice(null);
    try {
      await api.replaceSetupConfiguration(csrfToken, {
        org_name: form.orgName.trim(),
        default_project_name: form.projectName.trim(),
        allowed_email_domains: parseEmailDomains(form.domains),
      });
      const authorization = await api.createSetupOidcAuthorization(
        csrfToken,
        `${window.location.origin}/admin/setup/callback`,
      );
      window.location.assign(authorization.authorization_url);
    } catch (error) {
      setNotice(errorMessage(error));
      setBusy(false);
    }
  }

  return (
    <main className="setup-shell">
      <header className="product-bar">
        <div className="wordmark">
          <img src="/admin/clumsies-mark.svg" alt="" />
          <span>Clumsies</span>
        </div>
        <span className="server-label">{new URL(serverUrl).host}</span>
      </header>

      <div className="setup-workspace">
        <aside className="setup-progress" aria-label="Setup progress">
          <p className="eyebrow">Server setup</p>
          <h1>Claim this installation</h1>
          <ol>
            <ProgressStep index={1} label="Verify access" active={stage === "access"} complete={stage !== "access" && stage !== "loading"} />
            <ProgressStep index={2} label="Configure organization" active={stage === "configure"} complete={stage === "complete"} />
            <ProgressStep index={3} label="Bind first owner" active={false} complete={stage === "complete"} />
          </ol>
        </aside>

        <section className="setup-content" aria-live="polite">
          {notice && (
            <div className="notice" role="alert">
              <CircleAlert aria-hidden="true" />
              <span>{notice}</span>
            </div>
          )}

          {stage === "loading" && <LoadingState />}
          {stage === "access" && status && (
            <AccessStep
              status={status}
              setupCode={setupCode}
              busy={busy}
              onSetupCodeChange={setSetupCode}
              onSubmit={claimSetup}
            />
          )}
          {stage === "configure" && status && (
            <ConfigurationStep
              status={status}
              form={form}
              errors={errors}
              busy={busy}
              onChange={setForm}
              onSubmit={configureAndClaimOwner}
            />
          )}
          {stage === "complete" && <CompleteStep />}
        </section>
      </div>
    </main>
  );
}

function AccessStep({
  status,
  setupCode,
  busy,
  onSetupCodeChange,
  onSubmit,
}: {
  status: SetupStatus;
  setupCode: string;
  busy: boolean;
  onSetupCodeChange: (value: string) => void;
  onSubmit: (event: FormEvent<HTMLFormElement>) => void;
}) {
  return (
    <form className="setup-form" onSubmit={onSubmit}>
      <div className="section-heading">
        <KeyRound aria-hidden="true" />
        <div>
          <h2>Verify deployment access</h2>
          <p>Enter the Setup Code supplied through your deployment configuration.</p>
        </div>
      </div>
      {!status.setup_code_configured && (
        <div className="configuration-warning">
          Set <code>CLUMSIES_SETUP_CODE</code> and restart the Server before continuing.
        </div>
      )}
      <label className="field">
        <span>Setup Code</span>
        <input
          autoComplete="one-time-code"
          autoFocus
          disabled={!status.setup_code_configured || busy}
          onChange={(event) => onSetupCodeChange(event.target.value)}
          placeholder="Enter Setup Code"
          type="password"
          value={setupCode}
        />
      </label>
      <div className="form-actions">
        <button
          className="primary-button"
          disabled={!status.setup_code_configured || !setupCode.trim() || busy}
          type="submit"
        >
          {busy ? <LoaderCircle className="spin" aria-hidden="true" /> : <ArrowRight aria-hidden="true" />}
          Continue
        </button>
      </div>
    </form>
  );
}

function ConfigurationStep({
  status,
  form,
  errors,
  busy,
  onChange,
  onSubmit,
}: {
  status: SetupStatus;
  form: SetupForm;
  errors: SetupFormErrors;
  busy: boolean;
  onChange: (form: SetupForm) => void;
  onSubmit: (event: FormEvent<HTMLFormElement>) => void;
}) {
  return (
    <form className="setup-form" onSubmit={onSubmit}>
      <div className="section-heading">
        <ShieldCheck aria-hidden="true" />
        <div>
          <h2>Configure the organization</h2>
          <p>The verified OIDC identity will become the first Owner.</p>
        </div>
      </div>
      <div className="field-grid">
        <label className="field">
          <span>Organization name</span>
          <input
            aria-invalid={Boolean(errors.orgName)}
            disabled={busy}
            onChange={(event) => onChange({ ...form, orgName: event.target.value })}
            value={form.orgName}
          />
          {errors.orgName && <small>{errors.orgName}</small>}
        </label>
        <label className="field">
          <span>Default project</span>
          <input
            aria-invalid={Boolean(errors.projectName)}
            disabled={busy}
            onChange={(event) => onChange({ ...form, projectName: event.target.value })}
            value={form.projectName}
          />
          {errors.projectName && <small>{errors.projectName}</small>}
        </label>
      </div>
      <label className="field">
        <span>Allowed email domains</span>
        <input
          aria-invalid={Boolean(errors.domains)}
          disabled={busy}
          onChange={(event) => onChange({ ...form, domains: event.target.value })}
          placeholder="example.com, subsidiary.example.com"
          value={form.domains}
        />
        {errors.domains ? (
          <small>{errors.domains}</small>
        ) : (
          <small className="field-hint">Leave empty to allow the first verified identity from any domain.</small>
        )}
      </label>
      {!status.oidc_configured && (
        <div className="configuration-warning">
          Configure the Server OIDC environment before binding the first Owner.
        </div>
      )}
      <div className="form-actions">
        <button className="primary-button" disabled={!status.oidc_configured || busy} type="submit">
          {busy ? <LoaderCircle className="spin" aria-hidden="true" /> : <ArrowRight aria-hidden="true" />}
          Continue with SSO
        </button>
      </div>
    </form>
  );
}

function CompleteStep() {
  return (
    <div className="complete-state">
      <span className="complete-icon"><Check aria-hidden="true" /></span>
      <p className="eyebrow">Setup complete</p>
      <h2>Clumsies is ready</h2>
      <p>The installation is locked and the first Owner is bound to enterprise SSO.</p>
    </div>
  );
}

function LoginScreen({
  notice,
  serverUrl,
}: {
  notice: string | null;
  serverUrl: string;
}) {
  function beginLogin() {
    const authorization = new URL("/oauth2/authorization/oidc", serverUrl);
    const sameOrigin = authorization.origin === window.location.origin;
    const currentPath = window.location.pathname.startsWith("/admin")
      ? window.location.pathname
      : "/admin";
    const returnTo = sameOrigin
      ? currentPath
      : `${window.location.origin}/admin/`;
    authorization.searchParams.set("client_kind", "web_admin");
    authorization.searchParams.set("return_to", returnTo);
    window.location.assign(authorization);
  }

  return (
    <main className="login-shell">
      <div className="login-wordmark wordmark">
        <img src="/admin/clumsies-mark.svg" alt="" />
        <span>Clumsies</span>
      </div>
      <section className="login-panel" aria-labelledby="login-title">
        <span className="login-mark">
          <ShieldCheck aria-hidden="true" />
        </span>
        <h1 id="login-title">Organization administration</h1>
        <p>Sign in with the enterprise identity configured for this Server.</p>
        {notice && (
          <div className="notice" role="alert">
            <CircleAlert aria-hidden="true" />
            <span>{notice}</span>
          </div>
        )}
        <button className="primary-button login-button" onClick={beginLogin} type="button">
          <KeyRound aria-hidden="true" />
          Continue with SSO
        </button>
        <span className="server-label">{new URL(serverUrl).host}</span>
      </section>
    </main>
  );
}

function AppLoading() {
  return (
    <main className="bootstrap-state" aria-live="polite">
      <LoaderCircle className="spin" aria-hidden="true" />
      <span>Connecting to Server</span>
    </main>
  );
}

function FatalState({ message }: { message: string }) {
  return (
    <main className="bootstrap-state bootstrap-error">
      <CircleAlert aria-hidden="true" />
      <h1>Server unavailable</h1>
      <p>{message}</p>
      <button className="secondary-button" onClick={() => window.location.reload()} type="button">
        Retry
      </button>
    </main>
  );
}

function LoadingState() {
  return (
    <div className="loading-state">
      <LoaderCircle className="spin" aria-hidden="true" />
      <span>Reading Server state</span>
    </div>
  );
}

function ProgressStep({
  index,
  label,
  active,
  complete,
}: {
  index: number;
  label: string;
  active: boolean;
  complete: boolean;
}) {
  return (
    <li className={active ? "active" : complete ? "complete" : ""}>
      <span>{complete ? <Check aria-hidden="true" /> : index}</span>
      {label}
    </li>
  );
}

function resolveServerUrl(): string {
  const configured = import.meta.env.VITE_CLUMSIES_SERVER_URL?.trim();
  if (configured) return configured.replace(/\/+$/, "");
  if (window.location.port === "1421") return "http://127.0.0.1:18080";
  return window.location.origin;
}

function callbackError(): string | null {
  const error = new URLSearchParams(window.location.search).get("error");
  return error ? `Single sign-on did not complete: ${error}` : null;
}

function loginNotice(): string | null {
  const error = new URLSearchParams(window.location.search).get("error");
  if (!error) return null;
  if (error === "admin_access_required") {
    return "This account does not have organization administrator access.";
  }
  return `Single sign-on did not complete: ${error}`;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : "The Server could not complete this request.";
}
