import React from "react";
import ReactDOM from "react-dom/client";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { App } from "./App";
import { AuthenticationWindow } from "./AuthenticationWindow";
import "./styles.css";
import { UiProvider } from "./ui";
import { windowSurface } from "./window-surface";

const windowLabel =
  "__TAURI_INTERNALS__" in window ? getCurrentWindow().label : undefined;
const surface = windowSurface(window.location.search, windowLabel);
document.documentElement.dataset.surface = surface;
const Root = surface === "authentication" ? AuthenticationWindow : App;

ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
  <React.StrictMode>
    <UiProvider>
      <Root />
    </UiProvider>
  </React.StrictMode>,
);
