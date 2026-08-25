mod common;

use std::time::Duration;

use server::api::{
    CreateDraftRequest, DraftOperationAction, DraftOperationInput, DraftResourceContent,
    DraftResourceRef, ResourceScope,
};
use server::repository::{ServerError, ServerRepository};

#[tokio::test]
async fn metadata_and_draft_reads_skip_payloads_and_ref_locks() {
    let postgres = common::migrated_postgres().await;
    let repo = ServerRepository::new(postgres.pool.clone());
    let bootstrap = common::initialize_installation(
        postgres.pool.clone(),
        "Read Paths",
        "owner@example.com",
        "Owner",
        "oidc-subject-owner",
        "Read Paths",
    )
    .await;

    let org_memory = repo
        .create_org_context(&bootstrap.org_id, "context/selected.md", "# Selected")
        .await
        .unwrap();
    repo.select_org_resource_for_project(&bootstrap.project_id, &org_memory)
        .await
        .unwrap();
    let project_head = repo
        .get_project_commit_state(&bootstrap.project_id, None)
        .await
        .unwrap()
        .reference
        .commit_id
        .expect("project selection should create a project commit");
    repo.get_commit_payload(&project_head).await.unwrap();

    let draft = repo
        .create_draft(
            &bootstrap.user_id,
            CreateDraftRequest {
                daemon_installation_id: "daemon_read_paths".to_owned(),
                project_id: bootstrap.project_id.clone(),
                base_commit_id: Some(project_head.clone()),
                title: "Create project memory".to_owned(),
                description: None,
                resource: DraftResourceRef {
                    scope: ResourceScope::Project,
                    id: None,
                    path: Some("context/read-paths.md".to_owned()),
                },
                operations: vec![DraftOperationInput {
                    action: DraftOperationAction::Create,
                    resource: DraftResourceRef {
                        scope: ResourceScope::Project,
                        id: None,
                        path: Some("context/read-paths.md".to_owned()),
                    },
                    content: Some(DraftResourceContent {
                        description: None,
                        content: "# Read paths".to_owned(),
                    }),
                    new_path: None,
                }],
            },
        )
        .await
        .unwrap();

    let mut ref_lock = postgres.pool.begin().await.unwrap();
    sqlx::query_scalar::<_, String>(
        "SELECT ref_id
         FROM refs
         WHERE scope = 'project' AND project_id = $1 AND ref_name = 'refs/heads/main'
         FOR UPDATE",
    )
    .bind(&bootstrap.project_id)
    .fetch_one(&mut *ref_lock)
    .await
    .unwrap();

    let read = tokio::time::timeout(
        Duration::from_secs(3),
        repo.get_draft(&draft.draft.draft_id),
    )
    .await;
    ref_lock.rollback().await.unwrap();
    assert!(
        read.is_ok(),
        "a draft read must not wait for a ref mutation lock"
    );
    read.unwrap().unwrap();

    sqlx::query(
        "DELETE FROM tree_entries
         WHERE tree_id = (SELECT tree_id FROM commits WHERE commit_id = $1)",
    )
    .bind(&project_head)
    .execute(&postgres.pool)
    .await
    .unwrap();

    let state = repo
        .get_project_commit_state(&bootstrap.project_id, None)
        .await
        .unwrap();
    assert_eq!(state.latest.unwrap().commit_id, project_head);

    let commits = repo
        .list_project_commits(&bootstrap.project_id)
        .await
        .unwrap();
    assert!(
        commits
            .items
            .iter()
            .any(|commit| commit.commit_id == project_head)
    );
    assert!(matches!(
        repo.get_commit_payload(&project_head).await,
        Err(ServerError::InvalidRequest(_))
    ));
}
