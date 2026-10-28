# frozen_string_literal: true

module Agent
  # Applies the rows of a server's overrides form, all or nothing: edits and removals of its overrides, and a new
  # one when the blank row is filled in. What changed goes in the activity log.
  class ModelOverrideEditor
    FIELDS = %w[replacement_folder replacement_filename url sha256 note].freeze

    attr_reader :errors, :records, :changes

    def initialize(backend, user:, request: nil)
      @backend = backend
      @user = user
      @request = request
      @errors = []
      @records = []
      @changes = []
    end

    # rows: hashes with 'id' for an existing override (and 'remove' => '1' to delete it), or 'file'
    # ("folder/filename") and 'workflow_id' (blank for every workflow) for a new one, plus FIELDS.
    def apply!(rows)
      ModelOverride.transaction do
        rows.each { apply_row(it.stringify_keys) }
        raise ActiveRecord::Rollback if @errors.any?
      end
      log! if @errors.empty? && @changes.any?
      @errors.empty?
    end

    def notice
      @changes.empty? ? 'Nothing changed.' : "Saved: #{@changes.to_sentence}."
    end

    private

    def apply_row(row)
      return apply_new(row) if row['id'].blank?

      override = @backend.model_overrides.find_by(id: row['id'])
      return unless override

      @records << override
      return remove(override) if ActiveModel::Type::Boolean.new.cast(row['remove'])

      update(override, row)
    end

    # Marked too, so the form shows it still ticked if another row fails and nothing is saved.
    def remove(override)
      override.mark_for_destruction
      override.destroy!
      @changes << "removed #{override.path}#{scope_label(override)}"
    end

    def update(override, row)
      override.assign_attributes(row.slice(*FIELDS))
      return unless override.changed?

      save(override, "changed #{override.path}#{scope_label(override)}")
    end

    def apply_new(row)
      return if FIELDS.all? { row[it].blank? }

      folder, filename = row['file'].to_s.split('/', 2)
      override = @backend.model_overrides.build(folder:, filename:, workflow_id: row['workflow_id'].presence,
                                                created_by: @user, **row.slice(*FIELDS).symbolize_keys)
      @records << override
      save(override, "added #{override.path}#{scope_label(override)}")
    end

    def save(override, change)
      if override.save
        @changes << change
      else
        @errors.concat(override.errors.full_messages.map { "#{override.path.presence || 'New override'}: #{it}" })
      end
    end

    def scope_label(override) = override.workflow ? " for #{override.workflow.name}" : ''

    def log!
      ActivityLog.record(kind: :server_updated, user: @user, subject: @backend, request: @request,
                         message: "Changed model overrides on #{@backend.name}: #{@changes.to_sentence}",
                         details: { model_overrides: @changes })
    end
  end
end
