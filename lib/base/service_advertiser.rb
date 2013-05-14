module VCAP::Services
  class ServiceAdvertiser
    attr_reader :logger, :active

    def initialize(options)
      @current_catalog = options.fetch(:current_catalog)
      @catalog_in_ccdb = options.fetch(:catalog_in_ccdb)
      @http_handler = options.fetch(:http_handler)
      @logger = options.fetch(:logger)
      @active = options[:active] || true
      @offering_uri = "/v2/services"
      @service_plans_uri = "/v2/service_plans"
    end

    def advertise_services
      logger.debug("CCNG Catalog Manager: Registered in ccng: #{registered_services.inspect}")
      logger.debug("CCNG Catalog Manager: Current catalog: #{catalog_services.inspect}")

      active_services.each do |label|
        svc = @current_catalog[label]
        req, plans = @http_handler.generate_cc_advertise_offering_request(svc, active)
        guid = (@catalog_in_ccdb[label])["guid"]

        plans_to_add, plans_to_update = process_plans(plans, @catalog_in_ccdb[label]["service"]["plans"])
        logger.debug("CCNG Catalog Manager: plans_to_add = #{plans_to_add.inspect}")
        logger.debug("CCNG Catalog Manager: plans_to_update = #{plans_to_add.inspect}")

        logger.debug("CCNG Catalog Manager: Refresh offering: #{req.inspect}")
        advertise_service_to_cc(req, guid, plans_to_add, plans_to_update)
      end

      inactive_services.each do |label|
        svc = @catalog_in_ccdb[label]
        guid = svc["guid"]
        service = svc["service"]

        req, _ = @http_handler.generate_cc_advertise_offering_request(service, false)

        logger.debug("CCNG Catalog Manager: Deactivating offering: #{req.inspect}")
        advertise_service_to_cc(req, guid, [], {}) # don't touch plans, just deactivate
      end

      new_services.each do |label|
        svc = @current_catalog[label]
        req, plans = @http_handler.generate_cc_advertise_offering_request(svc, active)
        plans_to_add = plans.values
        logger.debug("CCNG Catalog Manager: plans_to_add = #{plans_to_add.inspect}")


        logger.debug("CCNG Catalog Manager: Add new offering: #{req.inspect}")
        advertise_service_to_cc(req, nil, plans_to_add, {}) # nil guid => new service, so add all plans
      end

      @active_count = active ? active_services.size + new_services.size : 0
      @disabled_count = inactive_services.size + (active ? 0 : active_services.size)

      logger.info("CCNG Catalog Manager: Found #{active_services.size} active, #{disabled_count} disabled and #{new_services.size} new service offerings")

    end

    def active_count
      @active_count || active ? active_services.size + new_services.size : 0
    end

    def disabled_count
      @disabled_count || inactive_services.size + (active ? 0 : active_services.size)
    end

    def inactive_services
      registered_services - active_services
    end

    def new_services
      catalog_services - active_services
    end

    def catalog_services
      @current_catalog.keys
    end

    def registered_services
      @catalog_in_ccdb.keys
    end

    def active_services
      catalog_services & registered_services
    end

    private
    def add_or_update_offering(offering, guid)
      update = !guid.nil?
      uri = update ? "#{@offering_uri}/#{guid}" : @offering_uri
      service_guid = nil

      logger.debug("CCNG Catalog Manager: #{update ? "Update" : "Advertise"} service offering #{offering.inspect} to cloud_controller: #{uri}")

      method = update ? "put" : "post"
      if method == 'put'
        offering.delete(:unique_id)
      end
      @http_handler.cc_http_request(:uri => uri,
                                    :method => method,
                                    :body => Yajl::Encoder.encode(offering)) do |http|
        if !http.error
          if (200..299) === http.response_header.status
            response = JSON.parse(http.response)
            logger.info("CCNG Catalog Manager: Advertise offering response (code=#{http.response_header.status}): #{response.inspect}")
            service_guid = response["metadata"]["guid"]
          else
            logger.error("CCNG Catalog Manager: Failed advertise offerings:#{offering.inspect}, status=#{http.response_header.status}")
          end
        else
          logger.error("CCNG Catalog Manager: Failed advertise offerings:#{offering.inspect}: #{http.error}")
        end
      end

      return service_guid
    end

    def advertise_service_to_cc(offering, guid, plans_to_add, plans_to_update)
      service_guid = add_or_update_offering(offering, guid)
      return false if service_guid.nil?

      return true if !offering[:active] # If deactivating, don't update plans

      logger.debug("CCNG Catalog Manager: Processing plans for: #{service_guid} -Add: #{plans_to_add.size} plans, Update: #{plans_to_update.size} plans")

      # Add plans to add
      plans_to_add.each { |plan|
        plan["service_guid"] = service_guid
        add_or_update_plan(plan)
      }

      # Update plans
      plans_to_update.each { |plan_guid, plan|
        add_or_update_plan(plan, plan_guid)
      }
      return true
    end

    def add_or_update_plan(plan, plan_guid = nil)
      add_plan = plan_guid.nil?
      uri = add_plan ? @service_plans_uri : "#{@service_plans_uri}/#{plan_guid}"
      logger.info("CCNG Catalog Manager: #{add_plan ? "Add new plan" : "Update plan (guid: #{plan_guid}) to"}: #{plan.inspect} via #{uri}")

      method = add_plan ? "post" : "put"
      @http_handler.cc_http_request(:uri => uri,
                                    :method => method,
                                    :body => Yajl::Encoder.encode(plan)) do |http|
        if !http.error
          if (200..299) === http.response_header.status
            logger.info("CCNG Catalog Manager: Successfully #{add_plan ? "added" : "updated"} service plan: #{plan.inspect}")
            return true
          else
            logger.error("CCNG Catalog Manager: Failed to #{add_plan ? "add" : "update"} plan: #{plan.inspect}, status=#{http.response_header.status}")
          end
        else
          logger.error("CCNG Catalog Manager: Failed to #{add_plan ? "add" : "update"} plan: #{plan.inspect}: #{http.error}")
        end
      end

      return false
    end

    public
    def process_plans(plans_from_catalog, plans_already_in_cc)
      plans_to_add = []
      plans_to_update = {}

      catalog_plans = plans_from_catalog.keys
      registered_plans = plans_already_in_cc.keys

      active_plans = catalog_plans & registered_plans
      active_plans.each { |plan_name|
        plan_details = plans_from_catalog[plan_name]

        if (plan_details["description"] != plans_already_in_cc[plan_name]["description"] ||
          plan_details["free"] != plans_already_in_cc[plan_name]["free"] ||
          plan_details["extra"] != plans_already_in_cc[plan_name]["extra"])
          plan_guid = plans_already_in_cc[plan_name]["guid"]
          plans_to_update[plan_guid] = {
            "name" => plan_name,
            "description" => plan_details["description"],
            "free" => plan_details["free"],
            "extra" => plan_details["extra"],
          }
          logger.debug("CCNG Catalog Manager: Updating plan: #{plan_name} to: #{plans_to_update[plan_guid].inspect}")
        else
          logger.debug("CCNG Catalog Manager: No changes to plan: #{plan_name}")
        end
      }

      new_plans = catalog_plans - active_plans
      new_plans.each { |plan_name|
        logger.debug("CCNG Catalog Manager: Adding new plan: #{plans_from_catalog[plan_name].inspect}")
        plans_to_add << plans_from_catalog[plan_name]
      }

      deactivated_plans = registered_plans - active_plans
      logger.warn("CCNG Catalog Manager: Found #{deactivated_plans.size} deactivated plans: - #{deactivated_plans.inspect}") unless deactivated_plans.empty?

      [plans_to_add, plans_to_update]
    end
  end
end