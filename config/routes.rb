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
  get 'welcome/sharing', to: 'onboarding#sharing', as: :welcome_sharing
  patch 'welcome/sharing', to: 'onboarding#update_sharing'

  get 'p/:token', to: 'public_shares#show', as: :public_share
  get 'p/:token/outputs/:index', to: 'public_shares#output', as: :public_share_output
  get 'queue', to: 'queue#index', as: :queue
  get 'shared', to: 'shared#index', as: :shared_index
  get 'shared/:id', to: 'shared#show', as: :shared
  post 'shared/:id/report', to: 'reports#create', as: :shared_report
  delete 'shared/:id', to: 'shared#unshare', as: :unshare_shared
  delete 'shared/:id/public_link', to: 'shared#revoke_public_link', as: :revoke_public_link_shared
  delete 'shared/:id/generation', to: 'shared#destroy_generation', as: :destroy_shared_generation

  post 'p/:token/report', to: 'public_reports#create', as: :public_share_report

  GenerationKind::ALL.each do |kind|
    get kind.path, to: 'studios#show', defaults: { kind: kind.key }, as: :"#{kind.key}_studio"
  end

  resources :generations, path: 'results', only: %i[index show create destroy] do
    member do
      post :retry
      post :cancel
      patch :share, action: :update_share
      post :public_link, action: :create_public_link
      delete :public_link, action: :revoke_public_link
    end
  end

  resource :settings, only: %i[show update]
  resource :public_links, only: %i[show destroy], path: 'settings/public-links'

  namespace :admin do
    resources :users, only: :index

    resources :backends, except: :show do
      post :check, on: :member
    end
    resource :privacy_notice, only: %i[edit update]
    resource :app_setting, only: %i[edit update]
    resources :reports, only: %i[index show update] do
      member do
        delete :unshare
        delete :revoke_public_link
        delete :generation, action: :destroy_generation
      end
    end
    resource :assistant_setting, only: %i[edit update]

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
