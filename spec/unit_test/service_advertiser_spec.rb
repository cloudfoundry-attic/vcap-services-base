require 'helper/spec_helper'
require 'base/service_advertiser'

module VCAP::Services
  describe ServiceAdvertiser do
    it 'advertises all services' do
      pending "needs a test"
    end

    describe "#process_plans" do
      let(:plan_name) { "plan1" }
      let(:plan_guid) { "abc" }
      let(:plan_details) {
        {"guid" => plan_guid, "description" => "blah", "free" => true, "extra" => "stuff"}
      }
      subject {
        described_class.new(current_catalog: nil,
                                    catalog_in_ccdb: nil,
                                    http_handler: stub,
                                    logger: mock.as_null_object)
      }

      describe "plans_to_add (first return value)" do
        context "when there is a new plan" do
          it "advertises the new plan" do
            new_plans = { plan_name => plan_details }
            plans_to_add, _ = subject.process_plans(new_plans, {})

            plans_to_add.should have(1).entry
            plans_to_add.first.should == plan_details
          end
        end

        context "when there are no new plans" do
          it "does not advertise any new plans" do
            plans = { plan_name => plan_details }

            plans_to_add, _ = subject.process_plans(plans, plans)

            plans_to_add.should be_empty
          end
        end
      end

      describe "plans_to_update (second return value)" do
        context "when no plans change" do
          it "should propose no changes to CC" do
            plans = {plan_name => plan_details}

            _, plans_to_update = subject.process_plans(plans, plans)
            plans_to_update.should be_empty
          end
        end

        context "when a plan's extra field has changed since it was last advertised" do
          it "should update the plan" do
            old_plans = { plan_name => plan_details.merge("extra" => "something") }
            new_plans = { plan_name => plan_details.merge("extra" => "something else") }

            _, plans_to_update = subject.process_plans( new_plans, old_plans )
            plans_to_update.should have_key(plan_guid)
            plans_to_update[plan_guid]['extra'].should == new_plans[plan_name]['extra']
          end
        end
      end
    end
  end
end