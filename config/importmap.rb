# Pin npm packages by running ./bin/importmap

pin 'application'
pin '@hotwired/turbo-rails', to: 'turbo.min.js'
pin '@hotwired/stimulus', to: 'stimulus.min.js'
pin '@hotwired/stimulus-loading', to: 'stimulus-loading.js'
pin_all_from 'app/javascript/controllers', under: 'controllers'
# UMD bundle with Popper included; it registers window.bootstrap and the data-api handlers.
# jspm's split ESM build of Popper pulls in chunks that `bin/importmap pin` doesn't vendor.
pin 'bootstrap', to: 'bootstrap.bundle.min.js' # @5.3.8
