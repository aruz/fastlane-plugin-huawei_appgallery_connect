require "fastlane_core/ui/ui"
require "json"
require "net/http"
require "securerandom"
require "uri"

module Fastlane
  UI = FastlaneCore::UI unless Fastlane.const_defined?("UI")

  module Helper
    class HuaweiAppgalleryConnectFileHelper
      DEFAULT_METADATA_PATH = "fastlane/metadata/huawei"
      SCREENSHOT_DIRECTORY_NAME = "screenshots"
      PACKAGE_FILE_TYPE = 5
      SCREENSHOT_FILE_TYPE = 2
      IMAGE_PARSE_TYPE = 1
      PORTRAIT_SCREENSHOT_SHOW_TYPE = 0
      LANDSCAPE_SCREENSHOT_SHOW_TYPE = 1
      SUPPORTED_SCREENSHOT_EXTENSIONS = [".jpg", ".jpeg", ".png"].freeze

      def self.upload_app(token, client_id, app_id, apk_path, is_aab)
        response_data = { "success" => false, "code" => 0 }
        upload_filename = is_aab ? "release.aab" : "release.apk"
        suffix = is_aab ? "aab" : "apk"

        upload_result = upload_file_for_obs(token, client_id, app_id, apk_path.to_s, upload_filename, suffix)
        return response_data unless upload_result[:success]

        UI.success("Upload app to AppGallery Connect successful")
        UI.important("Saving app information")

        result_json = save_app_file_info(
          token,
          client_id,
          app_id,
          PACKAGE_FILE_TYPE,
          [{
            fileName: upload_filename,
            fileDestUrl: upload_result[:file_dest_url],
            size: upload_result[:size].to_s
          }],
          "Cannot save app info",
          "App information saved."
        )

        response_data["success"] = true
        response_data["pkgVersion"] = result_json["pkgVersion"][0]
        response_data
      end

      def self.update_app_localization_info(token, params)
        metadata_path = params[:metadata_path] || DEFAULT_METADATA_PATH
        UI.important("Uploading app localization information from path: #{metadata_path}")

        locale_directories(metadata_path).each do |folder|
          lang = File.basename(folder)
          upload_locale_metadata(token, params, lang, folder)
          upload_locale_screenshots(token, params, lang, folder)
        end
      end

      def self.locale_directories(metadata_path)
        Dir.glob(File.join(metadata_path, "*")).select { |path| File.directory?(path) }.sort
      end

      def self.upload_locale_metadata(token, params, lang, folder)
        body = build_locale_metadata_body(lang, folder)
        return if body.nil?

        uri = URI.parse("https://connect-api.cloud.huawei.com/api/publish/v2/app-language-info?appId=#{params[:app_id]}")
        http = build_http_client(uri)
        request = Net::HTTP::Put.new(uri.request_uri)
        request["client_id"] = params[:client_id]
        request["Authorization"] = "Bearer #{token}"
        request["Content-Type"] = "application/json"
        request.body = body.to_json

        UI.important(request.body)
        response = http.request(request)
        UI.important(response)

        unless response.kind_of?(Net::HTTPSuccess)
          UI.user_error!("Cannot upload localization info (status code: #{response.code}, body: #{response.body})")
          return false
        end

        result_json = JSON.parse(response.body)
        if result_json["ret"]["code"].zero?
          UI.success("Successfully uploaded app localization info for #{lang}")
        else
          UI.user_error!(result_json)
        end
      end

      def self.upload_locale_screenshots(token, params, lang, folder)
        screenshot_directory = File.join(folder, SCREENSHOT_DIRECTORY_NAME)
        return unless Dir.exist?(screenshot_directory)
        screenshot_paths = Dir.glob(File.join(screenshot_directory, "*")).select { |path| File.file?(path) }.sort
        return if screenshot_paths.empty?

        validate_screenshot_paths!(lang, screenshot_paths)
        UI.important("Uploading #{screenshot_paths.length} screenshot(s) for #{lang}")

        uploaded_screenshots = screenshot_paths.map do |path|
          upload_result = upload_file_with_auth_code(token, params[:client_id], params[:app_id], path, IMAGE_PARSE_TYPE)
          build_screenshot_upload_result(path, upload_result)
        end

        save_app_file_info(
          token,
          params[:client_id],
          params[:app_id],
          SCREENSHOT_FILE_TYPE,
          build_screenshot_file_payloads(uploaded_screenshots),
          "Cannot upload screenshot info",
          "Successfully uploaded #{uploaded_screenshots.length} screenshot(s) for #{lang}",
          lang: lang,
          imgShowType: infer_img_show_type!(lang, uploaded_screenshots)
        )
      end

      def self.build_locale_metadata_body(lang, folder)
        body = { lang: lang }

        Dir.glob(File.join(folder, "*")).select { |path| File.file?(path) }.sort.each do |file|
          case File.basename(file)
          when "app_name"
            body[:appName] = File.read(file)
          when "app_description"
            body[:appDesc] = File.read(file)
          when "introduction"
            body[:briefInfo] = File.read(file)
          when "release_notes"
            body[:newFeatures] = File.read(file)
          end
        end

        body.keys == [:lang] ? nil : body
      end

      def self.validate_screenshot_paths!(lang, screenshot_paths)
        invalid_paths = screenshot_paths.reject { |path| supported_screenshot?(path) }
        return if invalid_paths.empty?

        invalid_names = invalid_paths.map { |path| File.basename(path) }.join(", ")
        UI.user_error!("Unsupported screenshot format for #{lang}: #{invalid_names}. Supported extensions: #{SUPPORTED_SCREENSHOT_EXTENSIONS.join(', ')}")
      end

      def self.supported_screenshot?(path)
        SUPPORTED_SCREENSHOT_EXTENSIONS.include?(File.extname(path).downcase)
      end

      def self.upload_file_for_obs(token, client_id, app_id, file_path, upload_filename, suffix)
        UI.message("Fetching upload URL")

        file_size_in_bytes = File.size(file_path)
        uri = URI.parse("https://connect-api.cloud.huawei.com/api/publish/v2/upload-url/for-obs?appId=#{app_id}&fileName=#{upload_filename}&contentLength=#{file_size_in_bytes}&suffix=#{suffix}")
        http = build_http_client(uri)
        request = Net::HTTP::Get.new(uri.request_uri)
        request["client_id"] = client_id
        request["Authorization"] = "Bearer #{token}"
        request["Content-Type"] = "application/json"
        response = http.request(request)

        unless response.kind_of?(Net::HTTPSuccess)
          UI.user_error!("Cannot obtain upload url, please check API Token / Permissions (status code: #{response.code})")
          return { success: false }
        end

        result_json = JSON.parse(response.body)
        if result_json["urlInfo"].nil? || result_json["urlInfo"]["url"].nil?
          UI.message("Cannot obtain upload url")
          UI.user_error!(response.body)
        end

        UI.important("Uploading app")
        upload_response = upload_binary_to_obs(result_json["urlInfo"], file_path)
        unless upload_response.kind_of?(Net::HTTPSuccess) && upload_response.code.to_i == 200
          UI.user_error!("Cannot upload app, please check API Token / Permissions (status code: #{upload_response.code}): #{upload_response.body}")
        end

        {
          success: true,
          file_dest_url: result_json["urlInfo"]["objectId"],
          size: file_size_in_bytes
        }
      end

      def self.upload_binary_to_obs(url_info, file_path)
        uri = URI(url_info["url"])
        http = build_http_client(uri)
        request = Net::HTTP::Put.new(uri)
        headers = url_info["headers"] || {}
        headers.each do |key, value|
          request[key] = value
        end
        request.body = File.binread(file_path)
        request.content_type = "application/octet-stream"
        http.request(request)
      end

      def self.upload_file_with_auth_code(token, client_id, app_id, file_path, parse_type = nil)
        upload_target = fetch_upload_url(token, client_id, app_id, File.extname(file_path).delete(".").downcase)
        upload_file(upload_target, file_path, parse_type)
      end

      def self.fetch_upload_url(token, client_id, app_id, suffix)
        uri = URI.parse("https://connect-api.cloud.huawei.com/api/publish/v2/upload-url?appId=#{app_id}&suffix=#{suffix}")
        http = build_http_client(uri)
        request = Net::HTTP::Get.new(uri.request_uri)
        request["client_id"] = client_id
        request["Authorization"] = "Bearer #{token}"
        request["Content-Type"] = "application/json"
        response = http.request(request)

        unless response.kind_of?(Net::HTTPSuccess)
          UI.user_error!("Cannot obtain upload url, please check API Token / Permissions (status code: #{response.code})")
        end

        result_json = JSON.parse(response.body)
        upload_url = result_json["uploadUrl"] || result_json.dig("urlInfo", "url")
        auth_code = result_json["authCode"] || result_json.dig("urlInfo", "authCode")
        file_dest_url = result_json["objectId"] ||
                        result_json["fileDestUrl"] ||
                        result_json["fileDestUlr"] ||
                        result_json.dig("urlInfo", "objectId") ||
                        result_json.dig("result", "UploadUrlRsp", "objectId")

        if upload_url.nil? || auth_code.nil?
          UI.user_error!("Cannot obtain upload url: #{response.body}")
        end

        {
          upload_url: upload_url,
          auth_code: auth_code,
          file_dest_url: file_dest_url
        }
      end

      def self.upload_file(upload_target, file_path, parse_type = nil)
        uri = URI(upload_target[:upload_url])
        http = build_http_client(uri)
        request = Net::HTTP::Post.new(uri.request_uri)
        boundary = "----FastlaneHuaweiAppGallery#{SecureRandom.hex(12)}"
        request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
        request.body = build_multipart_upload_body(boundary, upload_target[:auth_code], file_path, parse_type)
        response = http.request(request)

        unless response.kind_of?(Net::HTTPSuccess)
          UI.user_error!("Cannot upload file, please check API Token / Permissions (status code: #{response.code}, body: #{response.body})")
        end

        result_json = JSON.parse(response.body)
        upload_info = result_json.dig("result", "UploadFileRsp", "fileInfoList", 0)
        if upload_info.nil?
          UI.user_error!("Cannot parse uploaded file response: #{response.body}")
        end

        UI.important("Upload file response payload: #{upload_info}")

        file_dest_url = upload_target[:file_dest_url] || upload_info["fileDestUrl"] || upload_info["fileDestUlr"]
        if file_dest_url.nil?
          UI.user_error!("Cannot determine uploaded file object ID: #{response.body}")
        end

        {
          file_dest_url: file_dest_url,
          image_resolution: upload_info["imageResolution"]
        }
      end

      def self.build_multipart_upload_body(boundary, auth_code, file_path, parse_type = nil)
        body = "".dup
        body.force_encoding("ASCII-8BIT")
        append_multipart_field(body, boundary, "authCode", auth_code)
        append_multipart_field(body, boundary, "fileCount", "1")
        append_multipart_field(body, boundary, "name", File.basename(file_path))
        append_multipart_field(body, boundary, "parseType", parse_type.to_s) unless parse_type.nil?
        append_multipart_file(body, boundary, "file", file_path, mime_type_for(file_path))
        body << "--#{boundary}--\r\n"
        body
      end

      def self.append_multipart_field(body, boundary, name, value)
        body << "--#{boundary}\r\n"
        body << "Content-Disposition: form-data; name=\"#{name}\"\r\n\r\n"
        body << value.to_s
        body << "\r\n"
      end

      def self.append_multipart_file(body, boundary, name, file_path, mime_type)
        body << "--#{boundary}\r\n"
        body << "Content-Disposition: form-data; name=\"#{name}\"; filename=\"#{File.basename(file_path)}\"\r\n"
        body << "Content-Type: #{mime_type}\r\n\r\n"
        body << File.binread(file_path)
        body << "\r\n"
      end

      def self.mime_type_for(file_path)
        case File.extname(file_path).downcase
        when ".png"
          "image/png"
        when ".jpg", ".jpeg"
          "image/jpeg"
        when ".apk"
          "application/vnd.android.package-archive"
        else
          "application/octet-stream"
        end
      end

      def self.build_screenshot_upload_result(file_path, upload_result)
        {
          file_name: File.basename(file_path),
          file_dest_url: upload_result[:file_dest_url],
          image_resolution: upload_result[:image_resolution]
        }
      end

      def self.build_screenshot_file_payloads(uploaded_screenshots)
        uploaded_screenshots.map do |screenshot|
          {
            fileDestUrl: screenshot[:file_dest_url]
          }
        end
      end

      def self.infer_img_show_type!(lang, uploaded_screenshots)
        show_types = uploaded_screenshots.map do |screenshot|
          resolution_to_show_type!(lang, screenshot[:file_name], screenshot[:image_resolution])
        end.uniq

        return show_types.first if show_types.length == 1

        UI.user_error!("Screenshots for #{lang} must all use the same orientation because Huawei requires a single imgShowType per locale")
      end

      def self.resolution_to_show_type!(lang, file_name, image_resolution)
        match = image_resolution.to_s.match(/\A(\d+)\*(\d+)\z/)
        unless match
          UI.user_error!("Cannot determine screenshot orientation for #{lang}/#{file_name}: unexpected imageResolution #{image_resolution.inspect}")
        end

        width = match[1].to_i
        height = match[2].to_i
        return PORTRAIT_SCREENSHOT_SHOW_TYPE if height > width
        return LANDSCAPE_SCREENSHOT_SHOW_TYPE if width > height

        UI.user_error!("Cannot determine screenshot orientation for #{lang}/#{file_name}: square screenshots are not supported")
      end

      def self.save_app_file_info(token, client_id, app_id, file_type, files, failure_message, success_message, **additional_body)
        uri = URI.parse("https://connect-api.cloud.huawei.com/api/publish/v2/app-file-info?appId=#{app_id}")
        http = build_http_client(uri)
        request = Net::HTTP::Put.new(uri.request_uri)
        request["client_id"] = client_id
        request["Authorization"] = "Bearer #{token}"
        request["Content-Type"] = "application/json"

        body = { fileType: file_type, files: files }.merge(additional_body.reject { |_key, value| value.nil? })
        request.body = body.to_json
        UI.important("App file info request body: #{request.body}")

        response = http.request(request)
        unless response.kind_of?(Net::HTTPSuccess)
          UI.user_error!("#{failure_message} (status code: #{response.code}, body: #{response.body})")
        end

        result_json = JSON.parse(response.body)
        if result_json["ret"]["code"] == 0
          UI.success(success_message)
          result_json
        else
          UI.user_error!("#{failure_message}: #{result_json}")
        end
      end

      def self.build_http_client(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http
      end
    end
  end
end
