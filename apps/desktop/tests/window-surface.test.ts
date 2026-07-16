import { describe, expect, test } from "bun:test";
import { windowSurface } from "../src/window-surface";

describe("Desktop window surface", () => {
  test("selects only the explicit authentication surface", () => {
    expect(windowSurface("?surface=authentication")).toBe("authentication");
    expect(windowSurface("?surface=main")).toBe("main");
    expect(windowSurface("?surface=unknown")).toBe("main");
    expect(windowSurface("")).toBe("main");
  });

  test("uses the native label for a Tauri secondary window", () => {
    expect(windowSurface("", "authentication")).toBe("authentication");
    expect(windowSurface("", "main")).toBe("main");
  });
});
