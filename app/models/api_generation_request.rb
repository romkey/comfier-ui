# A durable user-scoped idempotency receipt. Retained if its generation is deleted, so a retry cannot
# accidentally submit the same work again. All receipt creation is serialized with the user's row lock.
class ApiGenerationRequest < ApplicationRecord
  belongs_to :user
  belongs_to :generation, optional: true
end
