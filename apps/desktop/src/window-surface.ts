export type WindowSurface = "main" | "authentication";

export function windowSurface(search: string, windowLabel?: string): WindowSurface {
  return windowLabel === "authentication" ||
    new URLSearchParams(search).get("surface") === "authentication"
    ? "authentication"
    : "main";
}
