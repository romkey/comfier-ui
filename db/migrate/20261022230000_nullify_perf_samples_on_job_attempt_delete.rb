# Deleting a result removes its job attempts with delete_all, which skips callbacks; the timing samples
# they produced stay for predictions, without the link.
class NullifyPerfSamplesOnJobAttemptDelete < ActiveRecord::Migration[8.1]
  def up
    remove_foreign_key :perf_samples, :job_attempts
    add_foreign_key :perf_samples, :job_attempts, on_delete: :nullify
  end

  def down
    remove_foreign_key :perf_samples, :job_attempts
    add_foreign_key :perf_samples, :job_attempts
  end
end
