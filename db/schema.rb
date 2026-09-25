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

ActiveRecord::Schema[8.1].define(version: 2026_09_25_190000) do
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

  create_table "app_settings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.decimal "email_notification_attachment_max_mb", precision: 8, scale: 3, default: "0.488", null: false
    t.decimal "slack_notification_attachment_max_mb", precision: 8, scale: 3, default: "5.0", null: false
    t.datetime "updated_at", null: false
  end

  create_table "backends", force: :cascade do |t|
    t.text "auth_token"
    t.string "base_url", null: false
    t.datetime "created_at", null: false
    t.boolean "downloader_available", default: false, null: false
    t.boolean "enabled", default: true, null: false
    t.datetime "inventory_checked_at"
    t.string "last_check_message"
    t.boolean "last_check_ok"
    t.datetime "last_checked_at"
    t.jsonb "manager_catalog", default: {}, null: false
    t.string "manager_version"
    t.jsonb "model_inventory", default: {}, null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["enabled"], name: "index_backends_on_enabled"
    t.index ["name"], name: "index_backends_on_name", unique: true
  end

  create_table "generations", force: :cascade do |t|
    t.bigint "backend_id"
    t.string "comfy_prompt_id"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.text "error_message"
    t.string "kind", null: false
    t.text "negative_prompt"
    t.jsonb "parameters", default: {}, null: false
    t.datetime "processing_ended_at"
    t.datetime "processing_started_at"
    t.text "prompt"
    t.float "run_seconds"
    t.boolean "share_input", default: false, null: false
    t.boolean "share_prompt", default: true, null: false
    t.datetime "shared_at"
    t.string "status", default: "queued", null: false
    t.datetime "submitted_at"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.bigint "workflow_id"
    t.string "workflow_name"
    t.index ["backend_id"], name: "index_generations_on_backend_id"
    t.index ["comfy_prompt_id"], name: "index_generations_on_comfy_prompt_id"
    t.index ["shared_at"], name: "index_generations_on_shared_at", where: "(shared_at IS NOT NULL)"
    t.index ["user_id", "kind", "created_at"], name: "index_generations_on_user_id_and_kind_and_created_at"
    t.index ["user_id", "status"], name: "index_generations_on_user_id_and_status"
    t.index ["user_id"], name: "index_generations_on_user_id"
    t.index ["workflow_id"], name: "index_generations_on_workflow_id"
  end

  create_table "model_downloads", force: :cascade do |t|
    t.bigint "backend_id", null: false
    t.string "comfy_prompt_id"
    t.datetime "created_at", null: false
    t.string "directory", null: false
    t.text "error_message"
    t.datetime "finished_at"
    t.string "name", null: false
    t.datetime "started_at"
    t.string "status", default: "queued", null: false
    t.datetime "updated_at", null: false
    t.text "url", null: false
    t.string "via"
    t.index ["backend_id", "directory", "name"], name: "index_model_downloads_one_active_per_file", unique: true, where: "((status)::text = ANY (ARRAY[('queued'::character varying)::text, ('running'::character varying)::text]))"
    t.index ["backend_id"], name: "index_model_downloads_on_backend_id"
  end

  create_table "privacy_notices", force: :cascade do |t|
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "version", default: 1, null: false
  end

  create_table "users", force: :cascade do |t|
    t.boolean "admin", default: false, null: false
    t.datetime "created_at", null: false
    t.string "default_aspect_ratio", default: "1:1", null: false
    t.text "default_negative_prompt"
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
    t.string "slack_name"
    t.string "slack_uid"
    t.string "uid", null: false
    t.datetime "updated_at", null: false
    t.string "username"
    t.index ["email"], name: "index_users_on_email"
    t.index ["preferred_backend_id"], name: "index_users_on_preferred_backend_id"
    t.index ["provider", "uid"], name: "index_users_on_provider_and_uid", unique: true
  end

  create_table "workflows", force: :cascade do |t|
    t.integer "base_resolution", default: 1024, null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.boolean "enabled", default: true, null: false
    t.jsonb "extra_models", default: [], null: false
    t.integer "frame_rate", default: 16, null: false
    t.jsonb "graph", default: {}, null: false
    t.float "guidance", default: 7.0, null: false
    t.string "kind", null: false
    t.string "name", null: false
    t.integer "position", default: 0, null: false
    t.integer "steps", default: 20, null: false
    t.datetime "updated_at", null: false
    t.index ["kind", "enabled", "position"], name: "index_workflows_on_kind_and_enabled_and_position"
    t.index ["kind", "name"], name: "index_workflows_on_kind_and_name", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "generations", "backends", on_delete: :nullify
  add_foreign_key "generations", "users", on_delete: :cascade
  add_foreign_key "generations", "workflows", on_delete: :nullify
  add_foreign_key "model_downloads", "backends", on_delete: :cascade
  add_foreign_key "users", "backends", column: "preferred_backend_id", on_delete: :nullify
end
