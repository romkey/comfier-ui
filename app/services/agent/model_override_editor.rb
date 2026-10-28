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
      @saves = {}
      @removals = {}
      @changes = []
    end

    # rows: hashes with 'id' for an existing override (and 'remove' => '1' to delete it), or 'file'
    # ("folder/filename") and 'workflow_id' (blank for every workflow) for a new one, plus FIELDS.
    # Every row is checked before anything is written, so a bad row leaves the form's records as they were typed
    # (a new one still new) rather than half-saved and rolled back.
    def apply!(rows)
      rows.each { stage(it.stringify_keys) }
      @saves.each_key { collect_errors(it) unless it.valid? }
      return false if @errors.any?

      write!
      true
    end

    def notice
      @changes.empty? ? 'Nothing changed.' : "Saved: #{@changes.to_sentence}."
    end

    private

    def write!
      ModelOverride.transaction do
        @removals.each_key(&:destroy!)
        @saves.each_key(&:save!)
      end
      @changes = @removals.values + @saves.values
      log! if @changes.any?
    end

    def stage(row)
      return stage_new(row) if row['id'].blank?

      override = @backend.model_overrides.find_by(id: row['id'])
      return unless override

      @records << override
      return stage_removal(override) if ActiveModel::Type::Boolean.new.cast(row['remove'])

      override.assign_attributes(row.slice(*FIELDS))
      @saves[override] = "changed #{override.path}#{scope_label(override)}" if override.changed?
    end

    # Marked, so the form shows it still ticked if another row has a problem and nothing is saved.
    def stage_removal(override)
      override.mark_for_destruction
      @removals[override] = "removed #{override.path}#{scope_label(override)}"
    end

    def stage_new(row)
      return if FIELDS.all? { row[it].blank? }

      folder, filename = row['file'].to_s.split('/', 2)
      override = @backend.model_overrides.build(folder:, filename:, workflow_id: row['workflow_id'].presence,
                                                created_by: @user, **row.slice(*FIELDS).symbolize_keys)
      @records << override
      @saves[override] = "added #{override.path}#{scope_label(override)}"
    end

    def collect_errors(override)
      @errors.concat(override.errors.full_messages.map { "#{override.path.presence || 'New override'}: #{it}" })
    end

    def scope_label(override) = override.workflow ? " for #{override.workflow.name}" : ''

    def log!
      ActivityLog.record(kind: :server_updated, user: @user, subject: @backend, request: @request,
                         message: "Changed model overrides on #{@backend.name}: #{@changes.to_sentence}",
                         details: { model_overrides: @changes })
    end
  end
end
