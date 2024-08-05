require 'json'
require 'net/http'

ANNOUNCE_URL = 'https://scc.suse.com/connect/subscriptions/systems'.freeze
ACTIVATE_PRODUCT_URL = 'https://scc.suse.com/connect/systems/products'.freeze
SYSTEMS_ACTIVATIONS_URL = 'https://scc.suse.com/connect/systems/activations'.freeze
DEREGISTER_SYSTEM_URL = 'https://scc.suse.com/connect/systems'.freeze
DEREGISTER_PRODUCT_URL = 'https://scc.suse.com/connect/systems/products'.freeze
NET_HTTP_ERRORS = [
  Errno::EINVAL,
  Errno::ECONNRESET,
  EOFError,
  Net::HTTPBadResponse,
  Net::HTTPForbidden,
  Net::HTTPGone,
  Net::HTTPBadRequest,
  Net::HTTPFound,
  Net::HTTPHeaderSyntaxError,
  Net::ProtocolError,
  Net::OpenTimeout,
  Net::HTTPServerException,
  Net::HTTPFatalError,
  OpenSSL::SSL::SSLError,
  Errno::EHOSTUNREACH,
  Net::HTTPRetriableError
].freeze

INSTANCE_ID_KEYS = {
  amazon: 'instanceId',
  google: 'instance_id',
  microsoft: 'vmId'
}.freeze

# rubocop:disable Metrics/ModuleLength
module SccProxy
  class << self

    # rubocop:disable ThreadSafety/ClassAndModuleAttributes
    attr_accessor :instance_id

    # rubocop:enable ThreadSafety/ClassAndModuleAttributes

    # rubocop:disable ThreadSafety/InstanceVariableInClassMethod
    def headers(auth, params)
      @instance_id = if params && params.class != String
                       get_instance_id(params)
                     else
                       # if it is not JSON, it is the system_token already
                       # announce system has metadata
                       # activate product does not have metadata
                       # so instance id comes as string
                       params
                     end

      {
        'accept' => 'application/json,application/vnd.scc.suse.com.v4+json',
        'Content-Type' => 'application/json',
        'Authorization' => auth,
        ApplicationController::SYSTEM_TOKEN_HEADER => @instance_id
      }
    end
    # rubocop:enable ThreadSafety/InstanceVariableInClassMethod

    def get_instance_id(params)
      verification_provider = InstanceVerification.provider.new(
        nil,
        nil,
        nil,
        params['instance_data']
      )
      instance_id_key = INSTANCE_ID_KEYS[params['hwinfo']['cloud_provider'].downcase.to_sym]
      iid = verification_provider.parse_instance_data
      iid[instance_id_key]
    end

    def prepare_scc_announce_request(uri_path, auth, params)
      scc_request = Net::HTTP::Post.new(uri_path, headers(auth, params))

      # Do not filter hardware information here but redirect the whole payload
      # to SCC.
      # SCC will make sure to handle the data correctly. This removes the need
      # to adapt here if information send by the client changes.
      scc_req_body = {
        hostname: params['hostname'],
        hwinfo: params['hwinfo'],
        byos_mode: params['proxy_byos_mode']
      }
      if params['proxy_byos_mode'].casecmp('hybrid').zero?
        scc_req_body[:login] = params['scc_login']
        scc_req_body[:password] = params['scc_password']
      end
      scc_request
    end

    def prepare_scc_request(uri_path, product, auth, params, mode)
      params_header = params
      if mode == 'byos'
        params_header = nil
      end
      scc_request = Net::HTTP::Post.new(uri_path, headers(auth, params_header))
      scc_request.body = {
        token: params[:token],
        identifier: product.identifier,
        version: product.version,
        arch: product.arch,
        release_type: product.release_type,
        email: params[:email] || nil,
        byos_mode: mode
      }.to_json
      scc_request
    end

    def announce_system_scc(auth, params)
      uri = URI.parse(ANNOUNCE_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      scc_request = prepare_scc_announce_request(uri.path, auth, params)
      response = http.request(scc_request)
      response.error! unless response.code_type == Net::HTTPCreated

      JSON.parse(response.body)
    end

    def scc_activate_product(product, auth, params, mode)
      uri = URI.parse(ACTIVATE_PRODUCT_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      scc_request = prepare_scc_request(uri.path, product, auth, params, mode)
      http.request(scc_request)
    end

    def deactivate_product_scc(auth, product, params)
      uri = URI.parse(DEREGISTER_PRODUCT_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      scc_request = Net::HTTP::Delete.new(uri.path, headers(auth, params))
      scc_request.body = {
        identifier: product.identifier,
        version: product.version,
        arch: product.arch,
        byos: true
      }.to_json
      http.request(scc_request)
    end

    def deregister_system_scc(auth, system_token)
      uri = URI.parse(DEREGISTER_SYSTEM_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      scc_request = Net::HTTP::Delete.new(uri.path, headers(auth, system_token))
      http.request(scc_request)
    end

    def parse_error(error_message, token = nil, email = nil)
      error_message = error_message[0..(error_message.index('json') - 1)].strip
      error_message = error_message.gsub(token, '').squish if token
      error_message = error_message.gsub(email, '').strip if email
      error_message
    end

    # rubocop:disable Metrics/CyclomaticComplexity
    # rubocop:disable Metrics/PerceivedComplexity
    def scc_check_subscription_expiration(headers, login, system_token, logger)
      auth = headers['HTTP_AUTHORIZATION'] if headers.include?('HTTP_AUTHORIZATION')
      uri = URI.parse(SYSTEMS_ACTIVATIONS_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      uri.query = URI.encode_www_form({ byos: true })
      scc_request = Net::HTTP::Get.new(uri.path, headers(auth, system_token))
      response = http.request(scc_request)
      unless response.code_type == Net::HTTPOK
        logger.info "Could not get the system (#{login}) activations, error: #{response.message} #{response.code}"
        response.message = SccProxy.parse_error(response.message) if response.message.include? 'json'
        return { is_active: false, message: response.message }
      end
      scc_systems_activations = JSON.parse(response.body)
      return { is_active: false, message: 'No activations.' } if scc_systems_activations.empty?

      no_status_products_ids = scc_systems_activations.map do |act|
        act['service']['product']['id'] if (act['status'].nil? && act['expires_at'].nil?)
      end.flatten.compact
      return { is_active: true } unless no_status_products_ids.all?(&:nil?)

      active_products_ids = scc_systems_activations.map { |act| act['service']['product']['id'] if act['status'].casecmp('active').zero? }.flatten
      products = Product.where(id: active_products_ids)
      product_paths = products.map { |prod| prod.repositories.pluck(:local_path) }.flatten
      active_subscription = product_paths.any? { |path| headers.fetch('X-Original-URI', '').include?(path) }
      if active_subscription
        { is_active: true }
      else
        # product not found in the active subscriptions, check the expired ones
        expired_products_ids = scc_systems_activations.map { |act| act['service']['product']['id'] unless act['status'].casecmp('active').zero? }.flatten
        if expired_products_ids.all?(&:nil?)
          return {
            is_active: false,
            message: 'Product not activated.'
          }
        end
        products = Product.where(id: expired_products_ids)
        product_paths = products.map { |prod| prod.repositories.pluck(:local_path) }.flatten
        expired_subscription = product_paths.any? { |path| headers.fetch('X-Original-URI', '').include?(path) }
        if expired_subscription
          {
            is_active: false,
            message: 'Subscription expired.'
          }
        else
          {
            is_active: false,
            message: 'Unexpected error when checking product subscription.'
          }
        end
      end
    end
    # rubocop:enable Metrics/PerceivedComplexity
    # rubocop:enable Metrics/CyclomaticComplexity
  end

  class Engine < ::Rails::Engine
    isolate_namespace SccProxy
    config.generators.api_only = true

    config.after_initialize do
      # replaces RMT registration for SCC registration
      Api::Connect::V3::Subscriptions::SystemsController.class_eval do
        def announce_system
          auth_header = nil
          auth_header = request.headers['HTTP_AUTHORIZATION'] if request.headers.include?('HTTP_AUTHORIZATION')
          system_information = hwinfo_params[:hwinfo].to_json

          if has_no_regcode?(auth_header)
            # no token sent to check with SCC
            # standard announce case
            @system = System.create!(hostname: params[:hostname], system_information: system_information, proxy_byos_mode: :payg)
          else
            request.request_parameters['proxy_byos_mode'] = 'byos'
            response = SccProxy.announce_system_scc(auth_header, request.request_parameters)
            @system = System.create!(
              system_token: SccProxy.instance_id,
              login: response['login'],
              password: response['password'],
              hostname: params[:hostname],
              proxy_byos_mode: :byos,
              system_information: system_information
            )
          end
          logger.info("System '#{@system.hostname}' announced")
          respond_with(@system, serializer: ::V3::SystemSerializer, location: nil)
        rescue *NET_HTTP_ERRORS => e
          logger.error(
            "Could not register system with regcode #{auth_header} " \
              "to SCC: #{e.message}"
          )
          render json: { type: 'error', error: e.message }, status: status_code(e.message), location: nil
        end

        protected

        def status_code(error_message)
          error_message[0..(error_message.index(' ') - 1)].to_i
        end

        def has_no_regcode?(auth_header)
          auth_header ||= '='
          auth_header = auth_header[(auth_header.index('=') + 1)..-1]
          auth_header.empty?
        end
      end

      Api::Connect::V3::Systems::ProductsController.class_eval do
        before_action :scc_activate_product, only: %i[activate]

        protected

        def scc_activate_product
          logger.info "Activating product #{@product.product_string} to SCC"
          auth = nil
          auth = request.headers['HTTP_AUTHORIZATION'] if request.headers.include?('HTTP_AUTHORIZATION')
          if @system.byos? || (!@system.byos? && !@product.free? && @product.extension?)
            mode = 'byos' if @system.byos?

            unless @system.byos?
              # system is not BYOS and
              # product is a non free extension
              mode = 'hybrid'
              # the extensions must be the same version and arch
              # than base product
              base_prod = @system.products.find_by(product_type: :base)
              if base_prod.present? && @product.arch == base_prod.arch && @product.version == base_prod.version
                request.headers['proxy_byos_mode'] = mode
                request.headers['scc_login'] = @system.login
                request.headers['scc_password'] = @system.password
                request.headers['instance_data'] = params[:instance_data]
                request.headers['hwinfo'] = params[:hwinfo]
                response = SccProxy.announce_system_scc(auth, request.headers)
              end
            end
            response = SccProxy.scc_activate_product(@product, auth, params, mode)

            unless response.code_type == Net::HTTPCreated
              error = JSON.parse(response.body)
              logger.info "Could not activate #{@product.product_string}, error: #{error['error']} #{response.code}"
              error['error'] = SccProxy.parse_error(error['error']) if error['error'].include? 'json'
              raise ActionController::TranslatedError.new(error['error'])
            end
            logger.info "Product #{@product.product_string} successfully activated with SCC"
            InstanceVerification.update_cache(request.remote_ip, @system.login, @product.id)
            # if the system was PAYG and the registration code is valid for the extension,
            # then the system is hybrid
            # update the system to HYBRID mode if HYBRID MODE and system not HYBRID already
            @system.hybrid! if mode == 'hybrid' && @system.payg?
          end
        end
      end

      Api::Connect::V4::Systems::ProductsController.class_eval do
        before_action :scc_deactivate_product, only: %i[destroy]

        protected

        def scc_deactivate_product
          auth = request.headers['HTTP_AUTHORIZATION']
          if @system.byos? && @product[:product_type] != 'base'
            response = SccProxy.deactivate_product_scc(auth, @product, @system.system_token)
            unless response.code_type == Net::HTTPOK
              error = JSON.parse(response.body)
              error['error'] = SccProxy.parse_error(error['error'], params[:token], params[:email]) if error['error'].include? 'json'
              logger.info "Could not de-activate product '#{@product.friendly_name}', error: #{error['error']} #{response.code}"
              raise ActionController::TranslatedError.new(error['error'])
            end
            logger.info "Product '#{@product.friendly_name}' successfully deactivated from SCC"
          end
        end
      end

      Api::Connect::V3::Systems::SystemsController.class_eval do
        before_action :scc_deregistration, only: %i[deregister]

        protected

        def scc_deregistration
          if @system.byos?
            auth = request.headers['HTTP_AUTHORIZATION']
            response = SccProxy.deregister_system_scc(auth, @system.system_token)
            unless response.code_type == Net::HTTPNoContent
              error = JSON.parse(response.body)
              logger.info "Could not de-activate system #{@system.login}, error: #{error['error']} #{response.code}"
              error['error'] = SccProxy.parse_error(error['error'], params[:token], params[:email]) if error['error'].include? 'json'
              raise ActionController::TranslatedError.new(error['error'])
            end
            logger.info 'System successfully deregistered from SCC'
          end
        end
      end

      ApplicationController.class_eval do
        # overwrite authenticate_system method
        # as BYOS in the cloud does not use SYSTEM_TOKEN headers
        def authenticate_system(skip_on_duplicated: false)
          authenticate_or_request_with_http_basic('RMT API') do |login, password|
            @systems = System.get_by_credentials(login, password)
            if @systems.present?
              # Return now if we just detected duplicates and we were told to skip on
              # this situation.
              return true if skip_on_duplicated && @systems.size > 1

              @system = get_system(@systems)
              if system_tokens_enabled? && request.headers.key?(ApplicationController::SYSTEM_TOKEN_HEADER)
                @system.update(last_seen_at: Time.zone.now)
                headers[ApplicationController::SYSTEM_TOKEN_HEADER] = @system.system_token
              elsif !@system.last_seen_at || @system.last_seen_at < 3.minutes.ago
                @system.touch(:last_seen_at)
              end
              true
            else
              logger.info _('Could not find system with login \"%{login}\" and password \"%{password}\"') %
                { login: login, password: password }
              error = ActionController::TranslatedError.new(N_('Invalid system credentials'))
              error.status = :unauthorized
              raise error
            end
          end
        end

        def get_system(systems)
          return nil if systems.blank?

          byos_systems_with_token = systems.select { |system| system.byos? && system.system_token }

          return systems.first if byos_systems_with_token.empty?

          system = byos_systems_with_token.first
          if byos_systems_with_token.length > 1
            # check for possible duplicated system_tokens
            duplicated_system_tokens = byos_systems_with_token.group_by { |sys| sys[:system_token] }.keys

            if duplicated_system_tokens.length > 1
              logger.info _('BYOS system with login \"%{login}\" authenticated and duplicated due to token (system tokens %{system_tokens}) mismatch') %
                { login: system.login, system_tokens: duplicated_system_tokens.join(',') }
            else
              # no different systems
              # first system is chosen
              logger.info _('BYOS system with login \"%{login}\" authenticated, system  token \"%{system_token}\"') %
                { login: system.login, system_token: system.system_token }
            end
          else
            logger.info _('BYOS system with login \"%{login}\" authenticated, system  token \"%{system_token}\"') %
              { login: system.login, system_token: system.system_token }
          end
          system
        end
      end
    end
  end
end
# rubocop:enable Metrics/ModuleLength
