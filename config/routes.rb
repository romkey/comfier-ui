require 'sidekiq/web'

Rails.application.routes.draw do
  get 'up' => 'rails/health#show', as: :rails_health_check

  get 'login', to: 'sessions#new', as: :login
  get 'auth/:provider/callback', to: 'sessions#create', as: :auth_callback
  get 'auth/failure', to: 'sessions#failure'
  post 'dev_login', to: 'dev_sessions#create', as: :dev_login
  delete 'logout', to: 'sessions#destroy', as: :logout

  get 'privacy', to: 'privacy#show', as: :privacy
  post 'privacy/accept', to: 'privacy#accept', as: :accept_privacy
  get 'queue', to: 'queue#index', as: :queue
  get 'shared', to: 'shared#index', as: :shared_index
  get 'shared/:id', to: 'shared#show', as: :shared
  delete 'shared/:id', to: 'shared#unshare', as: :unshare_shared

  GenerationKind::ALL.each do |kind|
    get kind.path, to: 'studios#show', defaults: { kind: kind.key }, as: :"#{kind.key}_studio"
  end

  resources :generations, path: 'results', only: %i[index show create destroy] do
    member do
      post :retry
      patch :share, action: :update_share
    end
  end

  resource :settings, only: %i[show update]

  namespace :admin do
    resources :backends, except: :show do
      post :check, on: :member
    end
    resource :privacy_notice, only: %i[edit update]

    resources :workflows, except: :show do
      member do
        get :models
        post :check_models
        post :install_models
      end
    end

    constraints(AdminConstraint) { mount Sidekiq::Web => 'sidekiq' }
  end

  root to: redirect('/image')
end
