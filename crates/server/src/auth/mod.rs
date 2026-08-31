pub(crate) mod api;
mod error;
pub(crate) mod http;
mod model;
mod postgres;
mod service;

pub use error::AuthError;
pub use model::{AuthPrincipal, OidcIdentity};
pub use service::{AuthService, DiscoveredOidcProvider, OidcIdentityProvider};

pub(crate) use model::user_capabilities;
