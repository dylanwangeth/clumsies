use crate::api::*;
use crate::auth::AuthPrincipal;
use crate::repository::{ServerError, ServerRepository};
use crate::shared::prefixed_id;

use super::postgres;

impl ServerRepository {
    pub async fn ensure_commit_access(
        &self,
        principal: &AuthPrincipal,
        commit_id: &str,
    ) -> Result<(), ServerError> {
        if postgres::commit_is_accessible(self.pool(), principal, commit_id).await? {
            Ok(())
        } else {
            Err(ServerError::not_found("commit", commit_id))
        }
    }

    pub async fn export_memory_state(&self, org_id: &str) -> Result<MemoryExport, ServerError> {
        postgres::export_memory_state(self.pool(), org_id).await
    }

    pub async fn create_org_context(
        &self,
        org_id: &str,
        path: &str,
        body: &str,
    ) -> Result<String, ServerError> {
        let resource_id = prefixed_id("mem");
        let mut tx = self.pool().begin().await?;
        postgres::insert_org_context(&mut tx, &resource_id, org_id, path, body).await?;
        let parent_commit_id = postgres::current_org_ref(&mut tx, org_id).await?;
        let commit_id =
            postgres::create_org_commit(&mut tx, org_id, parent_commit_id.as_deref()).await?;
        postgres::advance_org_ref(&mut tx, org_id, &commit_id).await?;
        tx.commit().await?;
        Ok(resource_id)
    }

    pub async fn select_org_resource_for_project(
        &self,
        project_id: &str,
        resource_id: &str,
    ) -> Result<(), ServerError> {
        let mut tx = self.pool().begin().await?;
        let org_id = postgres::project_org_id(&mut tx, project_id).await?;
        postgres::lock_org_ref_for_project_projection(&mut tx, &org_id).await?;
        let parent_commit_id = postgres::current_project_ref(&mut tx, project_id).await?;
        if !postgres::org_resource_exists(&mut tx, &org_id, resource_id).await? {
            return Err(ServerError::not_found("org_resource", resource_id));
        }
        let current_revision =
            postgres::current_project_org_selection_revision(&mut tx, project_id).await?;
        let next_revision = current_revision + 1;
        postgres::upsert_project_org_selection(&mut tx, project_id, resource_id, next_revision)
            .await?;
        postgres::validate_project_effective_memory(&mut tx, project_id, &org_id).await?;
        postgres::update_project_org_selection_revision(&mut tx, project_id, next_revision).await?;
        let commit_id =
            postgres::create_project_commit(&mut tx, project_id, parent_commit_id.as_deref())
                .await?;
        postgres::advance_project_ref(&mut tx, project_id, &commit_id).await?;
        tx.commit().await?;
        Ok(())
    }

    pub async fn replace_project_org_selection(
        &self,
        project_id: &str,
        expected_revision: i64,
        request: ReplaceProjectOrgSelectionRequest,
    ) -> Result<ProjectOrgSelection, ServerError> {
        let mut tx = self.pool().begin().await?;
        postgres::lock_org_draft_selection_coordination_for_project(&mut tx, project_id).await?;
        let org_id = postgres::project_org_id(&mut tx, project_id).await?;
        postgres::lock_org_ref_for_project_projection(&mut tx, &org_id).await?;
        let parent_commit_id = postgres::current_project_ref(&mut tx, project_id).await?;
        let current_revision =
            postgres::current_project_org_selection_revision(&mut tx, project_id).await?;
        if current_revision != expected_revision {
            return Err(ServerError::version_conflict(
                "project_org_selection",
                expected_revision,
                current_revision,
            ));
        }
        postgres::ensure_removed_org_resources_have_no_active_drafts(
            &mut tx,
            project_id,
            &request.resource_ids,
        )
        .await?;
        let next_revision = current_revision + 1;
        postgres::delete_project_org_selections(&mut tx, project_id).await?;
        postgres::insert_project_org_selection_items(
            &mut tx,
            project_id,
            &org_id,
            next_revision,
            &request.resource_ids,
        )
        .await?;
        postgres::update_project_org_selection_revision(&mut tx, project_id, next_revision).await?;
        let commit_id =
            postgres::create_project_commit(&mut tx, project_id, parent_commit_id.as_deref())
                .await?;
        postgres::advance_project_ref(&mut tx, project_id, &commit_id).await?;
        let selection = postgres::load_project_org_selection(&mut tx, project_id).await?;
        tx.commit().await?;
        Ok(selection)
    }

    pub async fn create_personal_bundle(
        &self,
        owner_user_id: &str,
        org_id: &str,
        request: PersonalBundleRequest,
    ) -> Result<PersonalBundleDetail, ServerError> {
        let mut tx = self.pool().begin().await?;
        postgres::user_ref(&mut tx, owner_user_id).await?;
        let bundle_id = prefixed_id("bdl");
        postgres::insert_personal_bundle(&mut tx, &bundle_id, owner_user_id, &request).await?;
        postgres::insert_bundle_items(&mut tx, &bundle_id, org_id, &request.resource_ids).await?;
        tx.commit().await?;
        self.get_personal_bundle(owner_user_id, &bundle_id).await
    }

    pub async fn list_personal_bundles(
        &self,
        owner_user_id: &str,
    ) -> Result<PersonalBundleListResponse, ServerError> {
        postgres::list_personal_bundles(self.pool(), owner_user_id).await
    }

    pub async fn get_personal_bundle(
        &self,
        owner_user_id: &str,
        bundle_id: &str,
    ) -> Result<PersonalBundleDetail, ServerError> {
        let mut tx = self.pool().begin().await?;
        postgres::ensure_bundle_owner(&mut tx, bundle_id, owner_user_id).await?;
        let detail = postgres::load_personal_bundle_detail(&mut tx, bundle_id).await?;
        tx.commit().await?;
        Ok(detail)
    }

    pub async fn update_personal_bundle(
        &self,
        owner_user_id: &str,
        org_id: &str,
        bundle_id: &str,
        expected_revision: i64,
        request: PersonalBundleUpdateRequest,
    ) -> Result<PersonalBundleDetail, ServerError> {
        let mut tx = self.pool().begin().await?;
        let current = postgres::lock_personal_bundle(&mut tx, bundle_id, owner_user_id).await?;
        if current.revision != expected_revision {
            return Err(ServerError::version_conflict(
                "bundle",
                expected_revision,
                current.revision,
            ));
        }
        let name = request.name.unwrap_or(current.name);
        let description = request.description.unwrap_or(current.description);
        postgres::update_personal_bundle_metadata(&mut tx, bundle_id, &name, &description).await?;
        postgres::replace_bundle_items_if_present(&mut tx, bundle_id, org_id, request.resource_ids)
            .await?;
        let detail = postgres::load_personal_bundle_detail(&mut tx, bundle_id).await?;
        tx.commit().await?;
        Ok(detail)
    }

    pub async fn delete_personal_bundle(
        &self,
        owner_user_id: &str,
        bundle_id: &str,
        expected_revision: i64,
    ) -> Result<DeleteResult, ServerError> {
        let mut tx = self.pool().begin().await?;
        let current_revision =
            postgres::lock_personal_bundle_revision(&mut tx, bundle_id, owner_user_id).await?;
        if current_revision != expected_revision {
            return Err(ServerError::version_conflict(
                "bundle",
                expected_revision,
                current_revision,
            ));
        }
        postgres::delete_personal_bundle(&mut tx, bundle_id).await?;
        tx.commit().await?;
        Ok(DeleteResult {
            deleted: true,
            id: bundle_id.to_owned(),
        })
    }

    pub async fn list_org_memories(&self, org_id: &str) -> Result<MemoryListResponse, ServerError> {
        Ok(MemoryListResponse {
            items: postgres::list_memory_meta(self.pool(), "org", Some(org_id), None).await?,
            page_info: crate::shared::page_info(),
        })
    }

    pub async fn list_project_memories(
        &self,
        project_id: &str,
    ) -> Result<MemoryListResponse, ServerError> {
        Ok(MemoryListResponse {
            items: postgres::list_memory_meta(self.pool(), "project", None, Some(project_id))
                .await?,
            page_info: crate::shared::page_info(),
        })
    }

    pub async fn get_org_memory(
        &self,
        org_id: &str,
        memory_id: &str,
    ) -> Result<MemoryDetail, ServerError> {
        let mut tx = self.pool().begin().await?;
        let detail =
            postgres::load_memory_detail(&mut tx, memory_id, "org", Some(org_id), None).await?;
        tx.commit().await?;
        Ok(detail)
    }

    pub async fn get_project_memory(
        &self,
        project_id: &str,
        memory_id: &str,
    ) -> Result<MemoryDetail, ServerError> {
        let mut tx = self.pool().begin().await?;
        let detail =
            postgres::load_memory_detail(&mut tx, memory_id, "project", None, Some(project_id))
                .await?;
        tx.commit().await?;
        Ok(detail)
    }

    pub async fn get_project_org_selection(
        &self,
        project_id: &str,
    ) -> Result<ProjectOrgSelection, ServerError> {
        let mut tx = self.pool().begin().await?;
        let selection = postgres::load_project_org_selection(&mut tx, project_id).await?;
        tx.commit().await?;
        Ok(selection)
    }

    pub async fn list_project_commits(
        &self,
        project_id: &str,
    ) -> Result<CommitListResponse, ServerError> {
        postgres::list_project_commits(self.pool(), project_id).await
    }

    pub async fn get_commit_payload(&self, commit_id: &str) -> Result<CommitPayload, ServerError> {
        let mut tx = self.pool().begin().await?;
        let payload = postgres::load_commit_payload(&mut tx, commit_id).await?;
        tx.commit().await?;
        Ok(payload)
    }

    pub async fn get_project_commit_state(
        &self,
        project_id: &str,
        local_commit_id: Option<&str>,
    ) -> Result<CommitStateResponse, ServerError> {
        let mut tx = self.pool().begin().await?;
        postgres::project_org_id(&mut tx, project_id).await?;
        let reference = postgres::load_project_ref(&mut tx, project_id).await?;
        let latest = match reference.commit_id.as_deref() {
            Some(commit_id) => Some(postgres::load_commit_metadata(&mut tx, commit_id).await?),
            None => None,
        };
        tx.commit().await?;
        Ok(CommitStateResponse {
            update_available: local_commit_id != reference.commit_id.as_deref(),
            download_url: reference
                .commit_id
                .as_ref()
                .map(|commit_id| format!("/api/v1/commits/{commit_id}")),
            reference,
            latest,
            incremental_supported: false,
        })
    }

    pub async fn list_org_commits(&self, org_id: &str) -> Result<CommitListResponse, ServerError> {
        postgres::list_org_commits(self.pool(), org_id).await
    }

    pub async fn get_org_commit_state(
        &self,
        org_id: &str,
        local_commit_id: Option<&str>,
    ) -> Result<CommitStateResponse, ServerError> {
        let mut tx = self.pool().begin().await?;
        let reference = postgres::load_org_ref(&mut tx, org_id).await?;
        let latest = match reference.commit_id.as_deref() {
            Some(commit_id) => Some(postgres::load_commit_metadata(&mut tx, commit_id).await?),
            None => None,
        };
        tx.commit().await?;
        Ok(CommitStateResponse {
            update_available: local_commit_id != reference.commit_id.as_deref(),
            download_url: reference
                .commit_id
                .as_ref()
                .map(|commit_id| format!("/api/v1/commits/{commit_id}")),
            reference,
            latest,
            incremental_supported: false,
        })
    }
}
