module TriannonClient
  class TriannonClient
    # Triannon may not support all content types in RDF::Format.content_types,
    # but the client code is more generic using this as a reasonable set; this
    # allows triannon to evolve support for anything supported by RDF::Format.
    CONTENT_TYPES = RDF::Format.content_types.keys

    JSONLD_TYPE = 'application/ld+json'
    PROFILE_IIIF = 'http://iiif.io/api/presentation/2/context.json'
    PROFILE_OA   = 'http://www.w3.org/ns/oa-context-20130208.json'
    CONTENT_TYPE_IIIF = "#{JSONLD_TYPE}; profile=\"#{PROFILE_IIIF}\""
    CONTENT_TYPE_OA   = "#{JSONLD_TYPE}; profile=\"#{PROFILE_OA}\""

    attr_reader :config
    attr_accessor :auth
    attr_accessor :site
    attr_accessor :container

    # Initialize a new triannon client
    # All params are set using ::TriannonClient.configuration
    def initialize
      # Configure triannon-app service
      @config = ::TriannonClient.configuration
      host = @config.host
      host.chomp!('/') if host.end_with?('/')
      @site = RestClient::Resource.new(
        host,
        cookies: {},
        headers: jsonld_payloads,
        open_timeout: 5,
        read_timeout: 30
      )
      @auth = @site['/auth']
      container = @config.container
      container = "/#{container}"  unless container.start_with?('/')
      container =  "#{container}/" unless container.end_with?('/')
      @container = @site[container]
    end

    # Reset authentication
    def authenticate!
      @access_expiry = nil
      authenticate
    end

    def authenticate
      if @access_expiry.to_i < Time.now.to_i
        @access_code = nil
        @site.headers.delete :Authorization
        @site.options[:cookies] = {}
      end
      @access_code || begin
        # 1. Obtain a client authorization code (short-lived token)
        return false if @config.client_id.empty? && @config.client_pass.empty?
        client = {
          clientId: @config.client_id,
          clientSecret: @config.client_pass
        }
        response = @auth["/client_identity"].post client.to_json, json_payloads
        @auth.options[:cookies] = response.cookies  # save the cookie data
        return false unless response.code == 200
        auth = JSON.parse(response.body)
        auth_code = auth['authorizationCode']
        return false if auth_code.nil?
        # 2. The client POSTs user credentials for a container, which modifies
        #    content in the cookies.
        return false if @config.container_user.empty? && @config.container_workgroups.empty?
        user = {
          userId: @config.container_user,
          workgroups: @config.container_workgroups
        }
        client_auth = "?code=#{auth_code}"
        response = @auth["/login#{client_auth}"].post user.to_json, json_payloads
        @auth.options[:cookies] = response.cookies  # save the cookie data
        return false unless response.code == 200
        # 3. The client, on behalf of user, obtains a long-lived access token.
        response = @auth["/access_token#{client_auth}"].get # no content type
        @auth.options[:cookies] = response.cookies  # save the cookie data
        return false unless response.code == 200
        access = JSON.parse(response.body)
        return false if access['accessToken'].nil?
        @access_code = "Bearer #{access['accessToken']}"
        @access_expiry = Time.now.to_i + access['expiresIn'].to_i
        @site.headers[:Authorization] = @access_code
      end
    end

    # Delete an annotation
    # @param id [String] an annotation ID
    # @response [true|false] true when successful
    def delete_annotation(id)
      tries = 0
      begin
        tries += 1
        check_id(id) if tries == 1
        authenticate if tries == 2
        response = @container[id].delete
        # HTTP DELETE response codes: A successful response SHOULD be
        # 200 (OK) if the response includes an entity describing the status,
        # 202 (Accepted) if the action has not yet been enacted, or
        # 204 (No Content) if the action has been enacted but the response
        # does not include an entity.
        return [200, 202, 204].include?(response.code)
      rescue RestClient::Exception => e
        msg = e.message
        response = e.response
        if response.is_a?(RestClient::Response)
          case response.code
          when 401
            retry if tries == 1
          when 403
            # DELETE is not authorized
          when 404, 410
            # If an annotation doesn't exist, consider it a 'success'
            return true
          end
          msg = response.body
        end
        @config.logger.error("Failed to DELETE annotation: #{id}, #{msg}")
        binding.pry if @config.debug
      rescue => e
        binding.pry if @config.debug
        @config.logger.error("Failed to DELETE annotation: #{id}, #{e.message}")
      end
      false
    end

    # POST and open annotation to triannon; the response contains an ID
    # @param oa [JSON-LD] a json-ld object with an open annotation context
    # @return response [RestClient::Response|nil]
    def post_annotation(oa)
      post_data = {
        'commit' => 'Create Annotation',
        'annotation' => {'data' => oa}
      }
      response = nil
      tries = 0
      begin
        tries += 1
        authenticate if tries == 2
        response = @container.post post_data
      rescue RestClient::Exception => e
        msg = e.message
        response = e.response
        if response.is_a?(RestClient::Response)
          case response.code
          when 401
            retry if tries == 1
          when 403
            # POST is not authorized
          end
          msg = "Failed to POST annotation: #{response.code}, #{response.body}"
        end
        binding.pry if @config.debug
        @config.logger.error(msg)
      rescue => e
        binding.pry if @config.debug
        @config.logger.error("Failed to POST annotation: #{e.message}")
      end
      return response
    end

    # Get annotations
    # @param content_type [String] HTTP mime type (defaults to 'application/ld+json')
    # @response [RDF::Graph] RDF::Graph of open annotations (can be empty on failure)
    def get_annotations(content_type=JSONLD_TYPE)
      g = RDF::Graph.new
      begin
        content_type = check_content_type(content_type)
        response = @container.get({:accept => content_type})
        g = response2graph(response)
      rescue => e
        msg = e.message
        r = e.response rescue nil
        if r.is_a?(RestClient::Response)
          case r.code
          when 404
            msg = "Failed to GET annotations: #{r.code}"
          else
            msg = "Failed to GET annotations: #{r.code}, #{r.body}"
          end
        end
        binding.pry if @config.debug
        @config.logger.error(msg)
      end
      g
    end

    # Get an annotation (with a default annotation context)
    # @param id [String] String representation of an annotation ID
    # @param content_type [String] HTTP mime type (defaults to 'application/ld+json')
    # @response [RDF::Graph] RDF::Graph of the annotation (can be empty on failure)
    def get_annotation(id, content_type=JSONLD_TYPE)
      g = RDF::Graph.new
      begin
        check_id(id)
        content_type = check_content_type(content_type)
        response = @container[id].get({:accept => content_type})
        g = response2graph(response)
      rescue => e
        msg = e.message
        r = e.response rescue nil
        if r.is_a?(RestClient::Response)
          case r.code
          when 404
            msg = "Failed to GET annotation: #{id}, #{r.code}"
          else
            msg = "Failed to GET annotation: #{id}, #{r.code}, #{r.body}"
          end
        end
        binding.pry if @config.debug
        @config.logger.error(msg)
      end
      g
    end

    # Get an annotation using a IIIF context
    # @param id [String] String representation of an annotation ID
    # @response [RDF::Graph] RDF::Graph of the annotation (can be empty on failure)
    def get_iiif_annotation(id)
      get_annotation(id, CONTENT_TYPE_IIIF)
    end

    # Get an annotation using an open annotation context
    # @param id [String] String representation of an annotation ID
    # @response [RDF::Graph] RDF::Graph of the annotation (can be empty on failure)
    def get_oa_annotation(id)
      get_annotation(id, CONTENT_TYPE_OA)
    end

    # Parse a Triannon response into an RDF::Graph; the graph can be empty
    # on failure to parse input.  The response must contain a content-type that
    # is available in RDF::Format.content_types (see code specs for details).
    # @param response [RestClient::Response] A RestClient::Response from Triannon
    # @response graph [RDF::Graph] An RDF::Graph instance
    def response2graph(response)
      unless response.is_a? RestClient::Response
        raise ArgumentError, 'response2graph only accepts a RestClient::Response'
      end
      g = RDF::Graph.new
      begin
        content_type = response.headers[:content_type]
        content_type = check_content_type(content_type)
        case content_type
        when /ld\+json/
          g = RDF::Graph.new.from_jsonld(response.body)
        when /turtle/
          g = RDF::Graph.new.from_ttl(response.body)
        else
          format = RDF::Format.for(:content_type => content_type)
          format.reader.new(response.body) do |reader|
            reader.each_statement {|s| g << s }
          end
        end
      rescue => e
        binding.pry if @config.debug
        @config.logger.error("Failed to parse response into RDF::Graph: #{e.message}")
      end
      g
    end

    # query an annotation graph to extract a URI for the first open annotation
    # @param graph [RDF::Graph] An RDF::Graph of an open annotation
    # @response uri [Array<RDF::URI>] An array of URIs for open annotations
    def annotation_uris(graph)
      raise ArgumentError, 'graph is not an RDF::Graph' unless graph.instance_of? RDF::Graph
      q = [:s, RDF.type, RDF::Vocab::OA.Annotation]
      graph.query(q).collect {|s| s.subject }
    end

    # extract an annotation ID from the URI
    # @param uri [RDF::URI] An RDF::URI for an annotation
    # @response id [String|nil] An ID for an annotation
    def annotation_id(uri)
      raise ArgumentError, 'uri is not an RDF::URI' unless uri.instance_of? RDF::URI
      path = uri.path.split(@config.container).last
      CGI::escape(path)
    end


    private

    def check_content_type(content_type)
      type = content_type.split(';').first # strip off any parameters
      unless CONTENT_TYPES.include? type
        msg = "#{type} not found in RDF::Format.content_types"
        raise ArgumentError, msg
      end
      type
    end

    def check_id(id)
      invalid =  ! id.instance_of?(String) || id.empty?
      raise ArgumentError, "Invalid ID: #{id}" if invalid
    end

    def json_payloads
      { accept: :json, content_type: :json }
    end

    def jsonld_payloads
      { accept: JSONLD_TYPE, content_type: JSONLD_TYPE }
    end

  end

end

