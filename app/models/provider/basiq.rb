require "cgi"

class Provider::Basiq
  include HTTParty

  headers "User-Agent" => "Sure Finance BASIQ Client"
  default_options.merge!(verify: true, ssl_verify_mode: OpenSSL::SSL::VERIFY_PEER, timeout: 120)

  attr_reader :api_key, :base_url, :version

  TOKEN_CACHE_KEY = "basiq:server_access_token"
  MAX_PAGINATION_PAGES = 100

  def initialize(api_key:, base_url: Rails.configuration.x.basiq.base_url, version: Rails.configuration.x.basiq.version)
    @api_key = api_key.to_s.strip
    @base_url = base_url.to_s.delete_suffix("/")
    @version = version.to_s
  end

  def server_access_token
    cached_token = Rails.cache.read(TOKEN_CACHE_KEY)
    return cached_token if cached_token.present?

    token_data = request_token(scope: "SERVER_ACCESS")
    token = token_data[:access_token] || token_data["access_token"]
    expires_in = (token_data[:expires_in] || token_data["expires_in"] || 3600).to_i
    raise BasiqError.new("BASIQ token response did not include access_token", :token_failed) if token.blank?

    Rails.cache.write(TOKEN_CACHE_KEY, token, expires_in: [ expires_in - 60, 60 ].max.seconds)
    token
  end

  def client_access_token(user_id:)
    token_data = request_token(scope: "CLIENT_ACCESS", userId: user_id)
    token = token_data[:access_token] || token_data["access_token"]
    raise BasiqError.new("BASIQ client token response did not include access_token", :token_failed) if token.blank?

    token
  end

  def create_user(email:)
    post_json("/users", { email: email })
  end

  def get_user(user_id)
    get_json("/users/#{escape(user_id)}")
  end

  def get_connections(user_id)
    get_paginated("/users/#{escape(user_id)}/connections")
  end

  def get_accounts(user_id)
    get_paginated("/users/#{escape(user_id)}/accounts")
  end

  def get_transactions(user_id, account_id: nil, limit: 500)
    query = { limit: limit }
    query[:filter] = "account.id.eq('#{account_id}')" if account_id.present?

    get_paginated("/users/#{escape(user_id)}/transactions", query: query)
  end

  def get_job(job_id)
    get_json("/jobs/#{escape(job_id)}")
  end

  def refresh_connection(user_id:, connection_id:)
    post_json("/users/#{escape(user_id)}/connections/#{escape(connection_id)}/refresh", {})
  end

  def delete_connection(user_id:, connection_id:)
    delete_json("/users/#{escape(user_id)}/connections/#{escape(connection_id)}")
  end

  def consent_url(client_token:, state:, action: nil)
    uri = URI.parse(Rails.configuration.x.basiq.consent_url)
    params = Rack::Utils.parse_nested_query(uri.query)
    params["token"] = client_token
    params["state"] = state if state.present?
    params["action"] = action if action.present?
    uri.query = URI.encode_www_form(params)
    uri.to_s
  end

  private

    def request_token(scope:, **extra_params)
      response = self.class.post(
        "#{base_url}/token",
        headers: basic_auth_headers.merge("Content-Type" => "application/x-www-form-urlencoded"),
        body: URI.encode_www_form({ scope: scope }.merge(extra_params.compact))
      )

      handle_response(response)
    rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
      raise BasiqError.new("BASIQ token request failed: #{e.message}", :request_failed)
    end

    def get_json(path_or_url, query: nil)
      response = self.class.get(absolute_url(path_or_url), headers: bearer_headers, query: query.presence)
      handle_response(response)
    rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
      raise BasiqError.new("BASIQ GET #{path_or_url} failed: #{e.message}", :request_failed)
    end

    def post_json(path, body)
      response = self.class.post(
        "#{base_url}#{path}",
        headers: bearer_headers.merge("Content-Type" => "application/json"),
        body: body.to_json
      )

      handle_response(response)
    rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
      raise BasiqError.new("BASIQ POST #{path} failed: #{e.message}", :request_failed)
    end

    def delete_json(path)
      response = self.class.delete("#{base_url}#{path}", headers: bearer_headers)
      return {} if response.code == 204

      handle_response(response)
    rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
      raise BasiqError.new("BASIQ DELETE #{path} failed: #{e.message}", :request_failed)
    end

    def get_paginated(path, query: nil)
      all_data = []
      first_response = nil
      next_url = path
      next_query = query
      page_count = 0

      while next_url.present?
        page_count += 1
        raise BasiqError.new("BASIQ pagination exceeded #{MAX_PAGINATION_PAGES} pages", :pagination_limit) if page_count > MAX_PAGINATION_PAGES

        page = get_json(next_url, query: next_query)
        first_response ||= page

        data = page[:data] || page["data"] || []
        all_data.concat(Array(data))

        links = page[:links] || page["links"] || {}
        next_url = links[:next] || links["next"]
        next_query = nil
      end

      (first_response || {}).merge(data: all_data)
    end

    def basic_auth_headers
      authorization = api_key.start_with?("Basic ") ? api_key : "Basic #{api_key}"
      {
        "Authorization" => authorization,
        "Accept" => "application/json",
        "basiq-version" => version
      }
    end

    def bearer_headers
      {
        "Authorization" => "Bearer #{server_access_token}",
        "Accept" => "application/json",
        "basiq-version" => version
      }
    end

    def handle_response(response)
      case response.code
      when 200, 201, 202
        parse_response_body(response)
      when 400
        raise BasiqError.new("Bad request to BASIQ API: #{response.body}", :bad_request)
      when 401
        Rails.cache.delete(TOKEN_CACHE_KEY)
        raise BasiqError.new("Invalid or expired BASIQ credentials", :unauthorized)
      when 403
        raise BasiqError.new("BASIQ access forbidden", :access_forbidden)
      when 404
        raise BasiqError.new("BASIQ resource not found", :not_found)
      when 409
        raise BasiqError.new("BASIQ conflict: #{response.body}", :conflict)
      when 429
        raise BasiqError.new("BASIQ rate limit exceeded", :rate_limited)
      else
        raise BasiqError.new("BASIQ API failed: #{response.code} #{response.message} - #{response.body}", :fetch_failed)
      end
    end

    def parse_response_body(response)
      return {} if response.body.blank?

      JSON.parse(response.body, symbolize_names: true)
    rescue JSON::ParserError
      raise BasiqError.new("Failed to parse BASIQ API response", :parse_error)
    end

    def absolute_url(path_or_url)
      return path_or_url if path_or_url.to_s.start_with?("http://", "https://")

      "#{base_url}#{path_or_url}"
    end

    def escape(value)
      CGI.escape(value.to_s)
    end

    class BasiqError < StandardError
      attr_reader :error_type

      def initialize(message, error_type = :unknown)
        super(message)
        @error_type = error_type
      end
    end
end
