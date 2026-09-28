# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"

# Customer Mini App (app/views/layouts/mini_app.html.erb). Preloaded only by its own page.
pin_all_from "app/javascript/mini_app", under: "mini_app", preload: "mini_app/app"
