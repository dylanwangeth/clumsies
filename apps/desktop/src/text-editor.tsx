import { useEffect, useMemo, useRef } from "react";
import { LanguageDescription } from "@codemirror/language";
import { languages } from "@codemirror/language-data";
import { Compartment, EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { basicSetup } from "codemirror";

type TextEditorProps = {
  ariaLabel: string;
  path: string;
  readOnly: boolean;
  value: string;
  onChange: (value: string) => void;
};

export function TextEditor({
  ariaLabel,
  onChange,
  path,
  readOnly,
  value,
}: TextEditorProps) {
  const parentRef = useRef<HTMLDivElement>(null);
  const viewRef = useRef<EditorView | null>(null);
  const onChangeRef = useRef(onChange);
  const syncingRef = useRef(false);
  const attributesConfig = useMemo(() => new Compartment(), []);
  const languageConfig = useMemo(() => new Compartment(), []);
  const readOnlyConfig = useMemo(() => new Compartment(), []);

  useEffect(() => {
    onChangeRef.current = onChange;
  }, [onChange]);

  useEffect(() => {
    if (!parentRef.current) {
      return;
    }

    const view = new EditorView({
      parent: parentRef.current,
      state: EditorState.create({
        doc: value,
        extensions: [
          basicSetup,
          EditorView.lineWrapping,
          attributesConfig.of(
            EditorView.contentAttributes.of({ "aria-label": ariaLabel }),
          ),
          languageConfig.of([]),
          readOnlyConfig.of([
            EditorState.readOnly.of(readOnly),
            EditorView.editable.of(!readOnly),
          ]),
          EditorView.updateListener.of((update) => {
            if (update.docChanged && !syncingRef.current) {
              onChangeRef.current(update.state.doc.toString());
            }
          }),
        ],
      }),
    });
    viewRef.current = view;

    return () => {
      view.destroy();
      viewRef.current = null;
    };
  }, [attributesConfig, languageConfig, readOnlyConfig]);

  useEffect(() => {
    const view = viewRef.current;
    if (!view) {
      return;
    }
    view.dispatch({
      effects: attributesConfig.reconfigure(
        EditorView.contentAttributes.of({ "aria-label": ariaLabel }),
      ),
    });
  }, [ariaLabel, attributesConfig]);

  useEffect(() => {
    const view = viewRef.current;
    if (!view || view.state.doc.toString() === value) {
      return;
    }
    syncingRef.current = true;
    view.dispatch({
      changes: { from: 0, to: view.state.doc.length, insert: value },
    });
    syncingRef.current = false;
  }, [value]);

  useEffect(() => {
    const view = viewRef.current;
    if (!view) {
      return;
    }
    view.dispatch({
      effects: readOnlyConfig.reconfigure([
        EditorState.readOnly.of(readOnly),
        EditorView.editable.of(!readOnly),
      ]),
    });
  }, [readOnly, readOnlyConfig]);

  useEffect(() => {
    let cancelled = false;
    const view = viewRef.current;
    if (!view) {
      return;
    }
    const description = LanguageDescription.matchFilename(languages, path);
    if (!description) {
      view.dispatch({ effects: languageConfig.reconfigure([]) });
      return;
    }
    void description
      .load()
      .then((support) => {
        if (!cancelled && viewRef.current === view) {
          view.dispatch({ effects: languageConfig.reconfigure(support) });
        }
      })
      .catch(() => {
        if (!cancelled && viewRef.current === view) {
          view.dispatch({ effects: languageConfig.reconfigure([]) });
        }
      });
    return () => {
      cancelled = true;
    };
  }, [languageConfig, path]);

  return <div className="text-editor" ref={parentRef} />;
}
