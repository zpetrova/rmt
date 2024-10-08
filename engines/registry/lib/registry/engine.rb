module Registry
  class << self
    def remove_auth_cache(registry_cache_key)
      cache_path = File.join(Rails.application.config.registry_cache_dir, registry_cache_key)
      File.unlink(cache_path) if File.exist?(cache_path)
    end
  end

  class Engine < ::Rails::Engine
    isolate_namespace Registry
    config.generators.api_only = true

    config.after_initialize do
      Api::Connect::V3::Systems::ActivationsController.class_eval do
        # only run instance verification if the instance metadata is present
        # and  run the cache refresh if instance metadata gets verified
        before_action :refresh_auth_cache, only: %w[index], if: -> { request.headers['X-Instance-Data'] }

        def refresh_auth_cache
          unless ZypperAuth.verify_instance(request, logger, @system)
            render(xml: { error: 'Instance verification failed' }, status: :forbidden)
          end
        end
      end

      Api::Connect::V3::Systems::SystemsController.class_eval do
        before_action :remove_auth_cache, only: %w[deregister]

        def remove_auth_cache
          registry_cache_key = [request.remote_ip, @system.login].join('-')
          Registry.remove_auth_cache(registry_cache_key)
        end
      end
    end
  end
end
