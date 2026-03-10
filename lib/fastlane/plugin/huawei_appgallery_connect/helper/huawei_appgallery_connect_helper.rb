require "cgi"
require "fastlane_core/ui/ui"
require "json"
require "net/http"
require "time"
require "uri"
require_relative "huawei_appgallery_connect_file_helper"

module Fastlane
  UI = FastlaneCore::UI unless Fastlane.const_defined?("UI")

  module Helper
    class HuaweiAppgalleryConnectHelper
      def self.get_token(client_id, client_secret)
        UI.important("Fetching app access token")

        uri = URI("https://connect-api.cloud.huawei.com/api/oauth2/v1/token")
        http = build_http_client(uri)
        request = Net::HTTP::Post.new(uri.path, "Content-Type" => "application/json")
        request.body = { client_id: client_id, grant_type: "client_credentials", client_secret: client_secret }.to_json

        result_json = JSON.parse(http.request(request).body)
        result_json["access_token"]
      end

      def self.get_app_id(token, client_id, package_id)
        UI.message("Fetching App ID")

        uri = URI.parse("https://connect-api.cloud.huawei.com/api/publish/v2/appid-list?packageName=#{package_id}")
        http = build_http_client(uri)
        request = Net::HTTP::Get.new(uri.request_uri)
        request["client_id"] = client_id
        request["Authorization"] = "Bearer #{token}"
        response = http.request(request)

        unless response.kind_of?(Net::HTTPSuccess)
          UI.user_error!("Cannot obtain app id, please check API Token / Permissions (status code: #{response.code})")
          return false
        end

        result_json = JSON.parse(response.body)
        if result_json["ret"]["code"] == 0
          UI.success("Successfully getting app id")
          result_json["appids"][0]["value"]
        else
          UI.user_error!("Failed to get app id: #{result_json}")
        end
      end

      def self.get_app_info(token, client_id, app_id)
        UI.message("Fetching App Info")

        uri = URI.parse("https://connect-api.cloud.huawei.com/api/publish/v2/app-info?appId=#{app_id}")
        http = build_http_client(uri)
        request = Net::HTTP::Get.new(uri.request_uri)
        request["client_id"] = client_id
        request["Authorization"] = "Bearer #{token}"
        response = http.request(request)

        unless response.kind_of?(Net::HTTPSuccess)
          UI.user_error!("Cannot obtain app info, please check API Token / Permissions (status code: #{response.code})")
          return false
        end

        result_json = JSON.parse(response.body)
        if result_json["ret"]["code"] == 0
          UI.success("Successfully getting app info")
          result_json["appInfo"]
        else
          UI.user_error!("Failed to get app info: #{result_json}")
        end
      end

      def self.update_appinfo(client_id, token, app_id, privacy_policy_url)
        UI.important("Updating app info")

        uri = URI.parse("https://connect-api.cloud.huawei.com/api/publish/v2/app-info?appId=#{app_id}")
        http = build_http_client(uri)
        request = Net::HTTP::Put.new(uri.request_uri)
        request["client_id"] = client_id
        request["Authorization"] = "Bearer #{token}"
        request["Content-Type"] = "application/json"
        request.body = { privacyPolicy: privacy_policy_url }.to_json

        response = http.request(request)
        unless response.kind_of?(Net::HTTPSuccess)
          UI.user_error!("Cannot update app info, please check API Token / Permissions (status code: #{response.code})")
          return false
        end

        result_json = JSON.parse(response.body)
        if result_json["ret"]["code"] == 0
          UI.success("Successfully updated app info")
        else
          UI.user_error!("Failed to update app info: #{result_json}")
        end
      end

      def self.upload_app(token, client_id, app_id, apk_path, is_aab)
        HuaweiAppgalleryConnectFileHelper.upload_app(token, client_id, app_id, apk_path, is_aab)
      end

      def self.query_aab_compilation_status(token, params, pkg_version)
        UI.important("Checking aab compilation status")
        uri = URI.parse("https://connect-api.cloud.huawei.com/api/publish/v2/aab/complile/status?appId=#{params[:app_id]}&pkgIds=#{pkg_version}")
        http = build_http_client(uri)
        request = Net::HTTP::Get.new(uri.request_uri)
        request["client_id"] = params[:client_id]
        request["Authorization"] = "Bearer #{token}"
        response = http.request(request)

        unless response.kind_of?(Net::HTTPSuccess)
          UI.user_error!("Cannot query compilation status (status code: #{response.code}, body: #{response.body})")
          return false
        end

        result_json = JSON.parse(response.body)
        if result_json["ret"]["code"] == 0
          result_json["pkgStateList"][0]["aabCompileStatus"]
        else
          UI.user_error!(result_json)
          -999
        end
      end

      def self.submit_app_for_review(token, params)
        UI.important("Submitting app for review")

        submission_config = build_submission_config(params)
        uri = URI.parse("https://connect-api.cloud.huawei.com/api/publish/v2/app-submit?appId=#{params[:app_id]}#{changelog_query(params)}#{submission_config[:release_type]}#{release_time_query(params)}")
        http = build_http_client(uri)
        request = Net::HTTP::Post.new(uri.request_uri)
        request["client_id"] = params[:client_id]
        request["Authorization"] = "Bearer #{token}"
        request["Content-Type"] = "application/json"
        request.body = submission_config[:body]

        UI.important("Request URL: #{uri}")
        UI.important("Request Body: #{request.body}")
        response = http.request(request)

        unless response.kind_of?(Net::HTTPSuccess)
          UI.user_error!("Cannot submit app for review (status code: #{response.code}, body: #{response.body})")
          return false
        end

        result_json = JSON.parse(response.body)
        if result_json["ret"]["code"] == 0
          UI.success("Successfully submitted app for review")
        elsif result_json["ret"]["code"] == 204_144_660 && result_json["ret"]["msg"].include?("It may take 2-5 minutes")
          UI.important(result_json)
          UI.important("Build is currently processing, waiting for 2 minutes before submitting again...")
          sleep(120)
          submit_app_for_review(token, params)
        else
          UI.user_error!("Failed to submit app for review: #{result_json}")
        end
      end

      def self.prepare_test_config(params)
        start_time = if params[:test_start_time]
                       Time.parse(params[:test_start_time])
                     else
                       Time.now + (60 * 60)
                     end

        end_time = if params[:test_end_time]
                     Time.parse(params[:test_end_time])
                   else
                     start_time + (80 * 24 * 60 * 60)
                   end

        {
          testStartTime: start_time.strftime("%Y-%m-%dT%H:%M:%S+0000"),
          testEndTime: end_time.strftime("%Y-%m-%dT%H:%M:%S+0000"),
          skipManualReview: params[:skip_manual_review] != false,
          feedbackEmail: params[:feedback_email],
          releaseType: 1,
          testPhase: true,
          testMode: 1
        }
      end

      def self.update_app_localization_info(token, params)
        HuaweiAppgalleryConnectFileHelper.update_app_localization_info(token, params)
      end

      def self.set_gms_dependency(token, client_id, app_id, gms_dependency)
        UI.message("Setting GMS Dependency")

        uri = URI.parse("https://connect-api.cloud.huawei.com/api/publish/v2/properties/gms?appId=#{app_id}")
        http = build_http_client(uri)
        request = Net::HTTP::Put.new(uri.request_uri)
        request["client_id"] = client_id
        request["Authorization"] = "Bearer #{token}"
        request["Content-Type"] = "application/json"
        request.body = { needGms: gms_dependency }.to_json

        response = http.request(request)
        unless response.kind_of?(Net::HTTPSuccess)
          UI.user_error!("Cannot update gms dependency, please check API Token / Permissions (status code: #{response.code})")
          return false
        end

        result_json = JSON.parse(response.body)
        if result_json["ret"]["code"] == 0
          UI.success("Successfully updated GMS Dependency")
        else
          UI.user_error!("Failed to update GMS Dependency: #{result_json}")
        end
      end

      def self.build_submission_config(params)
        if params[:use_testing_version]
          UI.important("Configuring open testing")
          test_config = prepare_test_config(params)

          {
            release_type: "&releaseType=1",
            body: test_config.to_json
          }
        elsif params[:phase_wise_release]
          validate_phase_wise_release!(params)

          {
            release_type: "&releaseType=3",
            body: {
              phasedReleaseStartTime: params[:phase_release_start_time],
              phasedReleaseEndTime: params[:phase_release_end_time],
              phasedReleasePercent: params[:phase_release_percent],
              phasedReleaseDescription: params[:phase_release_description]
            }.to_json
          }
        else
          {
            release_type: "",
            body: nil
          }
        end
      end

      def self.validate_phase_wise_release!(params)
        return unless params[:phase_release_start_time].nil? ||
                      params[:phase_release_end_time].nil? ||
                      params[:phase_release_percent].nil? ||
                      params[:phase_release_description].nil?

        UI.user_error!("Submit for review failed. Phase wise release requires Start time, End time Release Percent & Description")
      end

      def self.release_time_query(params)
        return "" if params[:release_time].nil?

        "&releaseTime=#{CGI.escape(params[:release_time])}"
      end

      def self.changelog_query(params)
        return "" if params[:changelog_path].nil?

        changelog_data = File.read(params[:changelog_path])
        if changelog_data.length < 3 || changelog_data.length > 500
          UI.user_error!("Failed to submit app for review. Changelog file length is invalid")
        end

        "&remark=#{CGI.escape(changelog_data)}"
      end

      def self.build_http_client(uri)
        HuaweiAppgalleryConnectFileHelper.build_http_client(uri)
      end
    end
  end
end
