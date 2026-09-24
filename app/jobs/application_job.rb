class ApplicationJob < ActiveJob::Base
  retry_on ActiveRecord::Deadlocked

  # A generation deleted while its job was waiting needs no further work.
  discard_on ActiveJob::DeserializationError
end
