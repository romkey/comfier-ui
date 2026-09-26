class ApplicationMailer < ActionMailer::Base
  default from: -> { ENV.fetch('MAIL_FROM', 'Comfier <comfier@localhost>') }
  layout 'mailer'
end
