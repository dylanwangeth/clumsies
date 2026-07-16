/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_CLUMSIES_SERVER_URL?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
