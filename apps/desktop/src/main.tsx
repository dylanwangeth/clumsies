import React from "react";
import ReactDOM from "react-dom/client";
import { App } from "./App";
import { AuthenticationWindow } from "./AuthenticationWindow";
import "./styles.css";
import { windowSurface } from "./window-surface";

const surface = windowSurface(window.location.search);
document.documentElement.dataset.surface = surface;
const Root = surface === "authentication" ? AuthenticationWindow : App;

ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
  <React.StrictMode>
    <Root />
  </React.StrictMode>,
);
