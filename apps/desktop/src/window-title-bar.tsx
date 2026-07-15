function isTauriRuntime(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

export function WindowTitleBar({ className = "" }: { className?: string }) {
  const classes = ["title-bar", className].filter(Boolean).join(" ");
  return (
    <div className={classes} data-tauri-drag-region>
      {!isTauriRuntime() ? (
        <div className="preview-traffic-lights" aria-hidden="true">
          <span />
          <span />
          <span />
        </div>
      ) : null}
    </div>
  );
}
