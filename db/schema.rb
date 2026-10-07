# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_07_180000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "citext"
  enable_extension "pg_catalog.plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "activity_logs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "details", default: {}, null: false
    t.string "ip_address"
    t.string "kind", null: false
    t.text "message", null: false
    t.bigint "subject_id"
    t.string "subject_type"
    t.text "user_agent"
    t.bigint "user_id"
    t.index ["created_at"], name: "index_activity_logs_on_created_at", order: :desc
    t.index ["kind", "created_at"], name: "index_activity_logs_on_kind_and_created_at"
    t.index ["kind"], name: "index_activity_logs_on_kind"
    t.index ["subject_type", "subject_id"], name: "index_activity_logs_on_subject"
    t.index ["user_id"], name: "index_activity_logs_on_user_id"
  end

  create_table "app_settings", force: :cascade do |t|
    t.boolean "allow_user_backends", default: true, null: false
    t.string "chat_default_model"
    t.text "chat_notice_text"
    t.string "chat_notice_url"
    t.datetime "created_at", null: false
    t.decimal "email_notification_attachment_max_mb", precision: 8, scale: 3, default: "0.488", null: false
    t.text "motd_text"
    t.text "placeholder_prompt"
    t.integer "report_auto_hide_threshold", default: 3, null: false
    t.integer "session_epoch", default: 0, null: false
    t.decimal "slack_notification_attachment_max_mb", precision: 8, scale: 3, default: "5.0", null: false
    t.datetime "updated_at", null: false
    t.integer "image_timeout_minutes", default: 20, null: false
    t.integer "video_timeout_minutes", default: 240, null: false
    t.integer "audio_timeout_minutes", default: 30, null: false
    t.integer "model_3d_timeout_minutes", default: 60, null: false
    t.text "video_script_prompt"
    t.text "album_art_prompt"
    t.bigint "album_art_workflow_id"
    t.index ["album_art_workflow_id"], name: "index_app_settings_on_album_art_workflow_id"
  end

  create_table "backend_inventories", force: :cascade do |t|
    t.bigint "backend_id", null: false
    t.datetime "created_at", null: false
    t.string "inventory_hash", null: false
    t.jsonb "models_json", default: {}, null: false
    t.jsonb "node_types_json", default: [], null: false
    t.string "object_info_hash"
    t.datetime "updated_at", null: false
    t.index ["backend_id"], name: "index_backend_inventories_on_backend_id", unique: true
  end

  create_table "backend_keys", force: :cascade do |t|
    t.bigint "backend_id", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.string "key_hash", null: false
    t.string "last_ip"
    t.datetime "last_rejected_at"
    t.string "last_rejected_reason"
    t.datetime "last_used_at"
    t.string "prefix", null: false
    t.datetime "revoked_at"
    t.datetime "updated_at", null: false
    t.index ["backend_id"], name: "index_backend_keys_on_backend_id"
    t.index ["prefix"], name: "index_backend_keys_on_prefix", unique: true
  end

  create_table "backend_load_hours", force: :cascade do |t|
    t.bigint "backend_id", null: false
    t.float "busy_local_s", default: 0.0, null: false
    t.float "busy_s", default: 0.0, null: false
    t.datetime "hour", null: false
    t.integer "jobs_completed", default: 0, null: false
    t.float "online_s", default: 0.0, null: false
    t.integer "queue_len_max", default: 0, null: false
    t.index ["backend_id", "hour"], name: "index_backend_load_hours_on_backend_id_and_hour", unique: true
  end

  create_table "backend_load_minutes", force: :cascade do |t|
    t.bigint "backend_id", null: false
    t.float "busy_local_s", default: 0.0, null: false
    t.float "busy_s", default: 0.0, null: false
    t.integer "jobs_completed", default: 0, null: false
    t.datetime "minute", null: false
    t.float "online_s", default: 0.0, null: false
    t.integer "queue_len_max", default: 0, null: false
    t.index ["backend_id", "minute"], name: "index_backend_load_minutes_on_backend_id_and_minute", unique: true
  end

  create_table "backend_models", force: :cascade do |t|
    t.bigint "backend_id", null: false
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "folder", null: false
    t.datetime "updated_at", null: false
    t.index ["backend_id", "filename"], name: "index_backend_models_on_backend_id_and_filename"
    t.index ["backend_id", "folder", "filename"], name: "index_backend_models_on_backend_id_and_folder_and_filename", unique: true
    t.index ["backend_id"], name: "index_backend_models_on_backend_id"
  end

  create_table "backend_object_infos", force: :cascade do |t|
    t.bigint "backend_id", null: false
    t.binary "blob_gz", null: false
    t.datetime "created_at", null: false
    t.string "object_info_hash", null: false
    t.datetime "updated_at", null: false
    t.index ["backend_id", "object_info_hash"], name: "index_backend_object_infos_on_backend_id_and_object_info_hash", unique: true
    t.index ["backend_id"], name: "index_backend_object_infos_on_backend_id"
  end

  create_table "backend_shares", force: :cascade do |t|
    t.bigint "backend_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["backend_id", "user_id"], name: "index_backend_shares_on_backend_id_and_user_id", unique: true
    t.index ["backend_id"], name: "index_backend_shares_on_backend_id"
    t.index ["user_id"], name: "index_backend_shares_on_user_id"
  end

  create_table "backend_speeds", force: :cascade do |t|
    t.bigint "backend_id", null: false
    t.float "busy_local_ewma_s"
    t.float "cold_penalty_ms"
    t.datetime "created_at", null: false
    t.integer "n_workflows", default: 0, null: false
    t.float "speed_index", default: 1.0, null: false
    t.datetime "updated_at", null: false
    t.index ["backend_id"], name: "index_backend_speeds_on_backend_id", unique: true
  end

  create_table "backends", force: :cascade do |t|
    t.string "agent_version"
    t.text "auth_token"
    t.string "auto_download_policy", default: "owner_jobs", null: false
    t.string "base_url"
    t.boolean "cleanup_after_run", default: false, null: false
    t.string "comfyui_version"
    t.datetime "connected_at"
    t.string "connection_kind", default: "legacy", null: false
    t.datetime "created_at", null: false
    t.datetime "deleted_at"
    t.string "description"
    t.jsonb "disabled_workflow_ids", default: [], null: false
    t.boolean "downloader_available", default: false, null: false
    t.boolean "enabled", default: true, null: false
    t.string "gpu_name"
    t.datetime "inventory_checked_at"
    t.string "last_check_message"
    t.boolean "last_check_ok"
    t.datetime "last_checked_at"
    t.datetime "last_seen_at"
    t.jsonb "last_status_json", default: {}, null: false
    t.datetime "last_status_persisted_at"
    t.jsonb "manager_catalog", default: {}, null: false
    t.string "manager_version"
    t.integer "max_queued_per_other_user", default: 3, null: false
    t.boolean "model_downloads_enabled", default: false, null: false
    t.jsonb "model_inventory", default: {}, null: false
    t.string "name", null: false
    t.string "offline_reason"
    t.datetime "offline_since"
    t.boolean "owner_priority", default: true, null: false
    t.bigint "owner_user_id"
    t.boolean "paused", default: false, null: false
    t.jsonb "system_json", default: {}, null: false
    t.datetime "updated_at", null: false
    t.string "visibility", default: "private", null: false
    t.bigint "vram_total"
    t.index ["enabled"], name: "index_backends_on_enabled"
    t.index ["name"], name: "index_backends_on_name", unique: true
    t.index ["owner_user_id"], name: "index_backends_on_owner_user_id"
  end

  create_table "chat_conversations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "model"
    t.string "title"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id", "updated_at"], name: "index_chat_conversations_on_user_id_and_updated_at"
    t.index ["user_id"], name: "index_chat_conversations_on_user_id"
  end

  create_table "chat_messages", force: :cascade do |t|
    t.bigint "chat_conversation_id", null: false
    t.text "content"
    t.datetime "created_at", null: false
    t.text "error"
    t.string "role", null: false
    t.string "status", default: "succeeded", null: false
    t.datetime "updated_at", null: false
    t.index ["chat_conversation_id"], name: "index_chat_messages_on_chat_conversation_id"
  end

  create_table "generation_inputs", force: :cascade do |t|
    t.bigint "bytes"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.bigint "generation_id", null: false
    t.string "input_id", null: false
    t.string "mime"
    t.string "sha256"
    t.string "storage_key", null: false
    t.datetime "updated_at", null: false
    t.index ["generation_id", "input_id"], name: "index_generation_inputs_on_generation_id_and_input_id", unique: true
    t.index ["generation_id"], name: "index_generation_inputs_on_generation_id"
  end

  create_table "generation_outputs", force: :cascade do |t|
    t.bigint "backend_id"
    t.bigint "bytes"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.bigint "generation_id", null: false
    t.string "kind", null: false
    t.string "mime"
    t.string "node", null: false
    t.string "storage_key"
    t.datetime "updated_at", null: false
    t.string "upload_id", null: false
    t.index ["backend_id"], name: "index_generation_outputs_on_backend_id"
    t.index ["generation_id"], name: "index_generation_outputs_on_generation_id"
    t.index ["upload_id"], name: "index_generation_outputs_on_upload_id", unique: true
  end

  create_table "generations", force: :cascade do |t|
    t.datetime "accepted_at"
    t.integer "agent_attempt", default: 0, null: false
    t.integer "agent_moves", default: 0, null: false
    t.string "agent_phase"
    t.float "agent_progress", default: 0.0
    t.string "agent_state"
    t.bigint "backend_id"
    t.datetime "cancel_requested_at"
    t.string "comfy_prompt_id"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.string "current_node"
    t.string "dispatch_request_id"
    t.datetime "dispatched_at"
    t.jsonb "error_json", default: {}, null: false
    t.text "error_message"
    t.jsonb "excluded_backend_ids", default: [], null: false
    t.jsonb "filled_workflow_json"
    t.datetime "hidden_for_review_at"
    t.string "kind", null: false
    t.datetime "last_terminal_at"
    t.string "model_set_hash"
    t.text "negative_prompt"
    t.jsonb "parameters", default: {}, null: false
    t.bigint "pinned_backend_id"
    t.datetime "predicted_end_at"
    t.integer "predicted_p90_ms"
    t.datetime "predicted_start_at"
    t.integer "predicted_total_ms"
    t.string "prediction_confidence"
    t.integer "prediction_source"
    t.datetime "processing_ended_at"
    t.datetime "processing_started_at"
    t.text "prompt"
    t.datetime "public_shared_at"
    t.string "public_token"
    t.float "queue_order"
    t.datetime "queued_at"
    t.float "run_seconds"
    t.datetime "running_at"
    t.datetime "shared_at"
    t.string "status", default: "queued", null: false
    t.string "structure_hash"
    t.datetime "submitted_at"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.boolean "warm", default: false, null: false
    t.float "work_units"
    t.bigint "workflow_id"
    t.string "workflow_name"
    t.bigint "album_art_generation_id"
    t.index ["album_art_generation_id"], name: "index_generations_on_album_art_generation_id"
    t.index ["backend_id", "agent_state"], name: "index_generations_on_backend_id_and_agent_state"
    t.index ["backend_id"], name: "index_generations_on_backend_id"
    t.index ["comfy_prompt_id"], name: "index_generations_on_comfy_prompt_id"
    t.index ["pinned_backend_id"], name: "index_generations_on_pinned_backend_id"
    t.index ["public_token"], name: "index_generations_on_public_token", unique: true, where: "(public_token IS NOT NULL)"
    t.index ["shared_at"], name: "index_generations_on_shared_at", where: "(shared_at IS NOT NULL)"
    t.index ["user_id", "kind", "created_at"], name: "index_generations_on_user_id_and_kind_and_created_at"
    t.index ["user_id", "status"], name: "index_generations_on_user_id_and_status"
    t.index ["user_id"], name: "index_generations_on_user_id"
    t.index ["workflow_id"], name: "index_generations_on_workflow_id"
  end

  create_table "job_attempts", force: :cascade do |t|
    t.integer "attempt", null: false
    t.bigint "backend_id"
    t.datetime "created_at", null: false
    t.datetime "ended_at"
    t.bigint "generation_id", null: false
    t.boolean "infra", default: false, null: false
    t.string "outcome", null: false
    t.integer "predicted_execute_ms"
    t.string "reason"
    t.datetime "started_at"
    t.jsonb "timings_json", default: {}, null: false
    t.datetime "updated_at", null: false
    t.boolean "warm", default: false, null: false
    t.index ["backend_id", "created_at"], name: "index_job_attempts_on_backend_id_and_created_at"
    t.index ["backend_id"], name: "index_job_attempts_on_backend_id"
    t.index ["generation_id"], name: "index_job_attempts_on_generation_id"
  end

  create_table "model_downloads", force: :cascade do |t|
    t.text "agent_detail"
    t.string "agent_download_id"
    t.string "agent_reason"
    t.string "agent_state"
    t.boolean "auto", default: false, null: false
    t.bigint "backend_id", null: false
    t.bigint "bytes_done", default: 0
    t.bigint "bytes_total"
    t.string "comfy_prompt_id"
    t.datetime "created_at", null: false
    t.string "directory", null: false
    t.text "error_message"
    t.datetime "finished_at"
    t.jsonb "for_generation_ids", default: [], null: false
    t.string "name", null: false
    t.bigint "requested_by_user_id"
    t.datetime "sent_at"
    t.string "sha256"
    t.bigint "speed_bps"
    t.datetime "started_at"
    t.string "status", default: "queued", null: false
    t.datetime "updated_at", null: false
    t.text "url", null: false
    t.string "via"
    t.index ["agent_download_id"], name: "index_model_downloads_on_agent_download_id", unique: true, where: "(agent_download_id IS NOT NULL)"
    t.index ["backend_id", "directory", "name"], name: "index_model_downloads_one_active_per_file", unique: true, where: "((status)::text = ANY (ARRAY[('queued'::character varying)::text, ('running'::character varying)::text]))"
    t.index ["backend_id"], name: "index_model_downloads_on_backend_id"
    t.index ["requested_by_user_id"], name: "index_model_downloads_on_requested_by_user_id"
  end

  create_table "perf_samples", force: :cascade do |t|
    t.bigint "backend_id", null: false
    t.float "cached_ratio", default: 0.0, null: false
    t.datetime "completed_at", null: false
    t.datetime "created_at", null: false
    t.integer "dispatch_ms"
    t.integer "execute_ms"
    t.bigint "input_bytes"
    t.integer "inputs_ms"
    t.bigint "job_attempt_id"
    t.integer "local_queue_ms"
    t.bigint "output_bytes"
    t.string "structure_hash"
    t.datetime "updated_at", null: false
    t.integer "upload_ms"
    t.boolean "warm", default: false, null: false
    t.float "work_units", default: 1.0, null: false
    t.bigint "workflow_id"
    t.index ["backend_id", "structure_hash", "warm"], name: "index_perf_samples_on_backend_id_and_structure_hash_and_warm"
    t.index ["backend_id"], name: "index_perf_samples_on_backend_id"
    t.index ["completed_at"], name: "index_perf_samples_on_completed_at"
    t.index ["job_attempt_id"], name: "index_perf_samples_on_job_attempt_id"
    t.index ["workflow_id"], name: "index_perf_samples_on_workflow_id"
  end

  create_table "perf_stats", force: :cascade do |t|
    t.bigint "backend_id", null: false
    t.datetime "created_at", null: false
    t.float "median_work_units"
    t.integer "n", default: 0, null: false
    t.float "output_bytes_ewma"
    t.float "sres2", default: 0.0, null: false
    t.string "structure_hash", null: false
    t.float "sw", default: 0.0, null: false
    t.float "swx", default: 0.0, null: false
    t.float "swxx", default: 0.0, null: false
    t.float "swxy", default: 0.0, null: false
    t.float "swy", default: 0.0, null: false
    t.datetime "updated_at", null: false
    t.boolean "warm", default: false, null: false
    t.bigint "workflow_id"
    t.index ["backend_id", "structure_hash", "warm"], name: "index_perf_stats_on_backend_id_and_structure_hash_and_warm", unique: true
    t.index ["backend_id"], name: "index_perf_stats_on_backend_id"
    t.index ["workflow_id"], name: "index_perf_stats_on_workflow_id"
  end

  create_table "prediction_logs", force: :cascade do |t|
    t.integer "actual_total_ms"
    t.bigint "backend_id"
    t.string "confidence"
    t.datetime "created_at", null: false
    t.bigint "generation_id", null: false
    t.integer "predicted_total_ms"
    t.integer "source"
    t.string "structure_hash"
    t.datetime "updated_at", null: false
    t.index ["backend_id"], name: "index_prediction_logs_on_backend_id"
    t.index ["created_at"], name: "index_prediction_logs_on_created_at"
    t.index ["generation_id"], name: "index_prediction_logs_on_generation_id"
  end

  create_table "privacy_notices", force: :cascade do |t|
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "version", default: 1, null: false
  end

  create_table "report_cases", force: :cascade do |t|
    t.string "conclusion"
    t.datetime "created_at", null: false
    t.bigint "generation_id"
    t.string "generation_title", null: false
    t.bigint "owner_id", null: false
    t.integer "reports_count", default: 0, null: false
    t.text "review_note"
    t.datetime "reviewed_at"
    t.bigint "reviewed_by_id"
    t.string "status", default: "open", null: false
    t.datetime "updated_at", null: false
    t.index ["generation_id", "status"], name: "index_report_cases_on_generation_id_and_status"
    t.index ["generation_id"], name: "index_report_cases_on_generation_id"
    t.index ["generation_id"], name: "index_report_cases_one_open_per_generation", unique: true, where: "(((status)::text = 'open'::text) AND (generation_id IS NOT NULL))"
    t.index ["owner_id"], name: "index_report_cases_on_owner_id"
    t.index ["reviewed_by_id"], name: "index_report_cases_on_reviewed_by_id"
    t.index ["status"], name: "index_report_cases_on_status"
  end

  create_table "reports", force: :cascade do |t|
    t.string "category", null: false
    t.citext "contact_email"
    t.datetime "created_at", null: false
    t.bigint "generation_id"
    t.text "reason", null: false
    t.bigint "report_case_id", null: false
    t.string "reporter_digest", null: false
    t.bigint "reporter_id"
    t.string "source", null: false
    t.datetime "updated_at", null: false
    t.index ["generation_id"], name: "index_reports_on_generation_id"
    t.index ["report_case_id", "reporter_digest"], name: "index_reports_on_report_case_id_and_reporter_digest", unique: true
    t.index ["report_case_id"], name: "index_reports_on_report_case_id"
    t.index ["reporter_id"], name: "index_reports_on_reporter_id"
  end

  create_table "source_credentials", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "host", null: false
    t.string "label"
    t.string "last4", null: false
    t.bigint "owner_user_id"
    t.text "secret", null: false
    t.datetime "updated_at", null: false
    t.index ["owner_user_id", "host"], name: "index_source_credentials_on_owner_user_id_and_host", unique: true
    t.index ["owner_user_id"], name: "index_source_credentials_on_owner_user_id"
  end

  create_table "transfer_stats", force: :cascade do |t|
    t.bigint "backend_id", null: false
    t.datetime "created_at", null: false
    t.float "ewma_bps"
    t.float "ewma_fixed_ms"
    t.string "host", default: "", null: false
    t.string "kind", null: false
    t.integer "n", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["backend_id", "kind", "host"], name: "index_transfer_stats_on_backend_id_and_kind_and_host", unique: true
    t.index ["backend_id"], name: "index_transfer_stats_on_backend_id"
  end

  create_table "users", force: :cascade do |t|
    t.boolean "admin", default: false, null: false
    t.string "backend_affinity", default: "auto", null: false
    t.datetime "created_at", null: false
    t.string "default_aspect_ratio", default: "1:1", null: false
    t.text "default_negative_prompt"
    t.boolean "delete_uploads_after_run", default: false, null: false
    t.string "dismissed_motd_digest"
    t.citext "email"
    t.datetime "last_signed_in_at"
    t.string "name"
    t.boolean "notify_email", default: false, null: false
    t.boolean "notify_include_asset", default: false, null: false
    t.boolean "notify_slack", default: false, null: false
    t.bigint "preferred_backend_id"
    t.datetime "privacy_accepted_at"
    t.integer "privacy_accepted_version"
    t.string "provider", null: false
    t.boolean "share_by_default"
    t.string "slack_name"
    t.string "slack_uid"
    t.string "uid", null: false
    t.datetime "updated_at", null: false
    t.string "username"
    t.index ["email"], name: "index_users_on_email"
    t.index ["preferred_backend_id"], name: "index_users_on_preferred_backend_id"
    t.index ["provider", "uid"], name: "index_users_on_provider_and_uid", unique: true
  end

  create_table "workflow_availabilities", force: :cascade do |t|
    t.bigint "backend_id", null: false
    t.datetime "created_at", null: false
    t.jsonb "details", default: {}, null: false
    t.string "status", null: false
    t.datetime "updated_at", null: false
    t.bigint "workflow_id", null: false
    t.index ["backend_id"], name: "index_workflow_availabilities_on_backend_id"
    t.index ["workflow_id", "backend_id"], name: "index_workflow_availabilities_on_workflow_id_and_backend_id", unique: true
    t.index ["workflow_id"], name: "index_workflow_availabilities_on_workflow_id"
  end

  create_table "workflow_models", force: :cascade do |t|
    t.bigint "bytes"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "folder", null: false
    t.string "sha256"
    t.string "source", default: "api", null: false
    t.datetime "updated_at", null: false
    t.text "url"
    t.bigint "workflow_id", null: false
    t.index ["workflow_id", "folder", "filename"], name: "index_workflow_models_on_workflow_id_and_folder_and_filename", unique: true
    t.index ["workflow_id"], name: "index_workflow_models_on_workflow_id"
  end

  create_table "workflows", force: :cascade do |t|
    t.integer "base_resolution", default: 1024, null: false
    t.datetime "created_at", null: false
    t.integer "default_timeout_s"
    t.text "description"
    t.boolean "enabled", default: true, null: false
    t.jsonb "extra_models", default: [], null: false
    t.integer "frame_rate", default: 16, null: false
    t.jsonb "graph", default: {}, null: false
    t.float "guidance", default: 7.0, null: false
    t.string "kind", null: false
    t.string "name", null: false
    t.integer "position", default: 0, null: false
    t.jsonb "requirements_json"
    t.boolean "requirements_need_review", default: false, null: false
    t.integer "steps", default: 20, null: false
    t.string "structure_hash"
    t.jsonb "ui_graph"
    t.datetime "updated_at", null: false
    t.index ["kind", "enabled", "position"], name: "index_workflows_on_kind_and_enabled_and_position"
    t.index ["kind", "name"], name: "index_workflows_on_kind_and_name", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "activity_logs", "users"
  add_foreign_key "app_settings", "workflows", column: "album_art_workflow_id", on_delete: :nullify
  add_foreign_key "backend_inventories", "backends"
  add_foreign_key "backend_keys", "backends"
  add_foreign_key "backend_load_hours", "backends"
  add_foreign_key "backend_load_minutes", "backends"
  add_foreign_key "backend_models", "backends"
  add_foreign_key "backend_object_infos", "backends"
  add_foreign_key "backend_shares", "backends"
  add_foreign_key "backend_shares", "users"
  add_foreign_key "backend_speeds", "backends"
  add_foreign_key "backends", "users", column: "owner_user_id"
  add_foreign_key "chat_conversations", "users"
  add_foreign_key "chat_messages", "chat_conversations"
  add_foreign_key "generation_inputs", "generations"
  add_foreign_key "generation_outputs", "backends"
  add_foreign_key "generation_outputs", "generations"
  add_foreign_key "generations", "backends", on_delete: :nullify
  add_foreign_key "generations", "generations", column: "album_art_generation_id", on_delete: :nullify
  add_foreign_key "generations", "users", on_delete: :cascade
  add_foreign_key "generations", "workflows", on_delete: :nullify
  add_foreign_key "job_attempts", "backends"
  add_foreign_key "job_attempts", "generations"
  add_foreign_key "model_downloads", "backends", on_delete: :cascade
  add_foreign_key "model_downloads", "users", column: "requested_by_user_id"
  add_foreign_key "perf_samples", "backends"
  add_foreign_key "perf_samples", "job_attempts"
  add_foreign_key "perf_samples", "workflows"
  add_foreign_key "perf_stats", "backends"
  add_foreign_key "perf_stats", "workflows"
  add_foreign_key "prediction_logs", "backends"
  add_foreign_key "prediction_logs", "generations"
  add_foreign_key "report_cases", "generations"
  add_foreign_key "report_cases", "users", column: "owner_id"
  add_foreign_key "report_cases", "users", column: "reviewed_by_id"
  add_foreign_key "reports", "generations"
  add_foreign_key "reports", "report_cases"
  add_foreign_key "reports", "users", column: "reporter_id"
  add_foreign_key "source_credentials", "users", column: "owner_user_id"
  add_foreign_key "transfer_stats", "backends"
  add_foreign_key "users", "backends", column: "preferred_backend_id", on_delete: :nullify
  add_foreign_key "workflow_availabilities", "backends"
  add_foreign_key "workflow_availabilities", "workflows"
  add_foreign_key "workflow_models", "workflows"
end
