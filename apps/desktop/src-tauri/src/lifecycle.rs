use std::sync::{Mutex, MutexGuard};

use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::webview::PageLoadEvent;
use tauri::{
    App, AppHandle, LogicalPosition, Manager, RunEvent, Runtime, TitleBarStyle, WebviewUrl,
    WebviewWindowBuilder, Window, WindowEvent,
};

const MAIN_WINDOW_LABEL: &str = "main";
const AUTHENTICATION_WINDOW_LABEL: &str = "authentication";
const TRAY_ICON_ID: &str = "clumsies";
const TRAY_SHOW_ID: &str = "clumsies.show";
const TRAY_QUIT_ID: &str = "clumsies.quit";
static WINDOW_TRANSITION: Mutex<()> = Mutex::new(());

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum LifecycleAction {
    ShowMainWindow,
    Quit,
}

pub fn setup<R: Runtime>(app: &mut App<R>) -> tauri::Result<()> {
    let show = MenuItem::with_id(app, TRAY_SHOW_ID, "Show Clumsies", true, None::<&str>)?;
    let separator = PredefinedMenuItem::separator(app)?;
    let quit = MenuItem::with_id(app, TRAY_QUIT_ID, "Quit Clumsies", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&show, &separator, &quit])?;

    let mut tray = TrayIconBuilder::with_id(TRAY_ICON_ID)
        .menu(&menu)
        .show_menu_on_left_click(false)
        .tooltip("Clumsies")
        .on_tray_icon_event(|tray, event| {
            if let Some(action) = tray_action(&event) {
                apply_action(tray.app_handle(), action);
            }
        });

    if let Some(icon) = app.default_window_icon() {
        tray = tray.icon(icon.clone());
    }
    #[cfg(target_os = "macos")]
    {
        tray = tray.icon_as_template(true);
    }
    tray.build(app)?;

    Ok(())
}

pub fn handle_menu_event<R: Runtime>(app: &AppHandle<R>, event: tauri::menu::MenuEvent) {
    if let Some(action) = menu_action(event.id().as_ref()) {
        apply_action(app, action);
    }
}

pub fn handle_window_event<R: Runtime>(window: &Window<R>, event: &WindowEvent) {
    if !is_managed_window(window.label()) {
        return;
    }
    if let WindowEvent::CloseRequested { api, .. } = event {
        api.prevent_close();
        let _ = window.hide();
    }
}

pub fn handle_run_event<R: Runtime>(app: &AppHandle<R>, event: &RunEvent) {
    #[cfg(target_os = "macos")]
    if let RunEvent::Reopen {
        has_visible_windows: false,
        ..
    } = event
    {
        apply_action(app, LifecycleAction::ShowMainWindow);
    }
}

fn menu_action(id: &str) -> Option<LifecycleAction> {
    match id {
        TRAY_SHOW_ID => Some(LifecycleAction::ShowMainWindow),
        TRAY_QUIT_ID => Some(LifecycleAction::Quit),
        _ => None,
    }
}

fn tray_action(event: &TrayIconEvent) -> Option<LifecycleAction> {
    match event {
        TrayIconEvent::Click {
            button: MouseButton::Left,
            button_state: MouseButtonState::Up,
            ..
        } => Some(LifecycleAction::ShowMainWindow),
        _ => None,
    }
}

fn apply_action<R: Runtime>(app: &AppHandle<R>, action: LifecycleAction) {
    match action {
        LifecycleAction::ShowMainWindow => {
            let _ = show_primary_window(app);
        }
        LifecycleAction::Quit => app.exit(0),
    }
}

pub fn present_main_window<R: Runtime>(app: &AppHandle<R>) -> tauri::Result<()> {
    let _transition = window_transition();
    if let Some(window) = app.get_webview_window(AUTHENTICATION_WINDOW_LABEL) {
        window.destroy()?;
    }
    show_window(app, MAIN_WINDOW_LABEL)
}

pub fn present_authentication_window<R: Runtime>(app: &AppHandle<R>) -> tauri::Result<()> {
    let _transition = window_transition();
    if let Some(main) = app.get_webview_window(MAIN_WINDOW_LABEL) {
        main.hide()?;
    }
    if app
        .get_webview_window(AUTHENTICATION_WINDOW_LABEL)
        .is_some()
    {
        return show_window(app, AUTHENTICATION_WINDOW_LABEL);
    }

    let builder = WebviewWindowBuilder::new(
        app,
        AUTHENTICATION_WINDOW_LABEL,
        WebviewUrl::App("index.html".into()),
    )
    .title("Clumsies")
    .inner_size(500.0, 560.0)
    .min_inner_size(500.0, 560.0)
    .max_inner_size(500.0, 560.0)
    .resizable(false)
    .maximizable(false)
    .center()
    .decorations(true)
    .visible(false)
    .focused(true)
    .on_page_load(|window, payload| {
        if matches!(payload.event(), PageLoadEvent::Finished) {
            let _ = window.show();
            let _ = window.set_focus();
        }
    });
    #[cfg(target_os = "macos")]
    let builder = builder
        .title_bar_style(TitleBarStyle::Overlay)
        .hidden_title(true)
        .traffic_light_position(LogicalPosition::new(14.0, 16.0));
    builder.build()?;
    app.show()?;
    Ok(())
}

fn show_primary_window<R: Runtime>(app: &AppHandle<R>) -> tauri::Result<()> {
    let _transition = window_transition();
    let label = primary_window_label(
        app.get_webview_window(AUTHENTICATION_WINDOW_LABEL)
            .is_some(),
    );
    show_window(app, label)
}

fn window_transition() -> MutexGuard<'static, ()> {
    WINDOW_TRANSITION
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn show_window<R: Runtime>(app: &AppHandle<R>, label: &str) -> tauri::Result<()> {
    app.show()?;
    if let Some(window) = app.get_webview_window(label) {
        window.show()?;
        window.unminimize()?;
        window.set_focus()?;
    }
    Ok(())
}

fn primary_window_label(authentication_window_exists: bool) -> &'static str {
    if authentication_window_exists {
        AUTHENTICATION_WINDOW_LABEL
    } else {
        MAIN_WINDOW_LABEL
    }
}

fn is_managed_window(label: &str) -> bool {
    matches!(label, MAIN_WINDOW_LABEL | AUTHENTICATION_WINDOW_LABEL)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tray_menu_actions_are_explicit() {
        assert_eq!(
            menu_action(TRAY_SHOW_ID),
            Some(LifecycleAction::ShowMainWindow)
        );
        assert_eq!(menu_action(TRAY_QUIT_ID), Some(LifecycleAction::Quit));
        assert_eq!(menu_action("unrelated"), None);
    }

    #[test]
    fn only_a_completed_primary_click_restores_the_window() {
        let primary_release = TrayIconEvent::Click {
            id: TRAY_ICON_ID.into(),
            position: tauri::PhysicalPosition::new(0.0, 0.0),
            rect: tauri::Rect {
                position: tauri::Position::Physical(tauri::PhysicalPosition::new(0, 0)),
                size: tauri::Size::Physical(tauri::PhysicalSize::new(18, 18)),
            },
            button: MouseButton::Left,
            button_state: MouseButtonState::Up,
        };
        let secondary_release = TrayIconEvent::Click {
            id: TRAY_ICON_ID.into(),
            position: tauri::PhysicalPosition::new(0.0, 0.0),
            rect: tauri::Rect {
                position: tauri::Position::Physical(tauri::PhysicalPosition::new(0, 0)),
                size: tauri::Size::Physical(tauri::PhysicalSize::new(18, 18)),
            },
            button: MouseButton::Right,
            button_state: MouseButtonState::Up,
        };

        assert_eq!(
            tray_action(&primary_release),
            Some(LifecycleAction::ShowMainWindow)
        );
        assert_eq!(tray_action(&secondary_release), None);
    }

    #[test]
    fn authentication_window_is_primary_until_session_load_completes() {
        assert_eq!(primary_window_label(true), AUTHENTICATION_WINDOW_LABEL);
        assert_eq!(primary_window_label(false), MAIN_WINDOW_LABEL);
    }

    #[test]
    fn close_hides_only_managed_desktop_windows() {
        assert!(is_managed_window(MAIN_WINDOW_LABEL));
        assert!(is_managed_window(AUTHENTICATION_WINDOW_LABEL));
        assert!(!is_managed_window("oauth-callback"));
    }
}
