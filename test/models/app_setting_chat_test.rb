require 'test_helper'

class AppSettingChatTest < ActiveSupport::TestCase
  test 'chat notice url must be http or https when present' do
    settings = app_settings(:default)
    settings.chat_notice_url = 'ftp://example.com'

    assert_not settings.valid?
    assert_includes settings.errors[:chat_notice_url], 'is invalid'

    settings.chat_notice_url = 'https://example.com extra'

    assert_not settings.valid?
  end

  test 'allowed_chat_notice_redirect_url accepts https and rejects invalid values' do
    settings = app_settings(:default)
    settings.chat_notice_url = 'https://chat.example.com/path'

    assert_equal 'https://chat.example.com/path', settings.allowed_chat_notice_redirect_url

    settings.chat_notice_url = 'javascript:alert(1)'

    assert_nil settings.allowed_chat_notice_redirect_url
  end

  test 'chat_notice? is true when text is present' do
    settings = app_settings(:default)
    settings.chat_notice_text = 'Use the main chat bot'

    assert_predicate settings, :chat_notice?
  end
end
