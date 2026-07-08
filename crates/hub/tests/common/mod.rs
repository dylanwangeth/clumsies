use sqlx::PgPool;
use testcontainers::ContainerAsync;
use testcontainers::runners::AsyncRunner;
use testcontainers_modules::postgres::Postgres;

pub struct TestPostgres {
    _container: ContainerAsync<Postgres>,
    pub pool: PgPool,
}

pub async fn migrated_postgres() -> TestPostgres {
    let container = Postgres::default().start().await.unwrap();
    let port = container.get_host_port_ipv4(5432).await.unwrap();
    let url = format!("postgres://postgres:postgres@127.0.0.1:{port}/postgres");
    let pool = PgPool::connect(&url).await.unwrap();

    hub::db::run_migrations(&pool).await.unwrap();

    TestPostgres {
        _container: container,
        pool,
    }
}
