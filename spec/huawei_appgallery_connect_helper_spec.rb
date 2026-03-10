require "json"
require "fileutils"
require "spec_helper"
require "tmpdir"

describe Fastlane::Helper::HuaweiAppgalleryConnectHelper do
  let(:token) { "token-123" }
  let(:metadata_path) { Dir.mktmpdir("huawei-metadata") }
  let(:params) do
    {
      client_id: "client-id",
      app_id: "app-id",
      metadata_path: metadata_path
    }
  end

  after do
    FileUtils.rm_rf(metadata_path)
  end

  def http_client(&block)
    instance_double("Net::HTTP").tap do |http|
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:request, &block)
    end
  end

  def http_response(options)
    body = options.fetch(:body)
    code = options[:code] || "200"
    success = options.key?(:success) ? options[:success] : true

    instance_double("Net::HTTPResponse", body: body, code: code).tap do |response|
      allow(response).to receive(:kind_of?).with(Net::HTTPSuccess).and_return(success)
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(success)
    end
  end

  def write_file(path, contents)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, contents)
  end

  it "uploads text metadata without touching screenshots" do
    locale_path = File.join(metadata_path, "en-US")
    write_file(File.join(locale_path, "app_name"), "Example App")
    write_file(File.join(locale_path, "app_description"), "Description")
    write_file(File.join(locale_path, "introduction"), "Brief")
    write_file(File.join(locale_path, "release_notes"), "Notes")

    text_http = http_client do |request|
      expect(request).to be_a(Net::HTTP::Put)
      expect(request.path).to eq("/api/publish/v2/app-language-info?appId=app-id")

      body = JSON.parse(request.body)
      expect(body).to eq(
        "lang" => "en-US",
        "appName" => "Example App",
        "appDesc" => "Description",
        "briefInfo" => "Brief",
        "newFeatures" => "Notes"
      )

      http_response(body: { ret: { code: 0 } }.to_json)
    end

    expect(Net::HTTP).to receive(:new).once.and_return(text_http)

    described_class.update_app_localization_info(token, params)
  end

  it "uploads locale screenshots through upload-url, upload, and app-file-info" do
    screenshot_path = File.join(metadata_path, "en-US", "screenshots", "01.png")
    write_file(screenshot_path, "png-data")

    request_order = []

    upload_url_http = http_client do |request|
      request_order << :upload_url
      expect(request).to be_a(Net::HTTP::Get)
      expect(request.path).to eq("/api/publish/v2/upload-url?appId=app-id&suffix=png")

      http_response(body: { uploadUrl: "https://upload.example.com/files", authCode: "auth-1" }.to_json)
    end

    upload_http = http_client do |request|
      request_order << :upload
      expect(request).to be_a(Net::HTTP::Post)
      expect(request["Content-Type"]).to include("multipart/form-data")
      expect(request.body).to include("name=\"authCode\"")
      expect(request.body).to include("auth-1")
      expect(request.body).to include("name=\"fileCount\"")
      expect(request.body).to include("name=\"parseType\"")
      expect(request.body).to include("filename=\"01.png\"")

      http_response(
        body: {
          result: {
            UploadFileRsp: {
              fileInfoList: [{
                fileDestUlr: "screenshots/01.png",
                size: "8",
                imageResolution: "1080x1920",
                imageResolutionSingature: "sig-1"
              }]
            }
          }
        }.to_json
      )
    end

    register_http = http_client do |request|
      request_order << :register
      expect(request).to be_a(Net::HTTP::Put)
      expect(request.path).to eq("/api/publish/v2/app-file-info?appId=app-id")

      body = JSON.parse(request.body)
      expect(body["lang"]).to eq("en-US")
      expect(body["fileType"]).to eq(2)
      expect(body["files"]).to eq([{
        "fileName" => "01.png",
        "fileDestUrl" => "screenshots/01.png",
        "size" => "8",
        "imageResolution" => "1080x1920",
        "imageResolutionSingature" => "sig-1"
      }])

      http_response(body: { ret: { code: 0 } }.to_json)
    end

    expect(Net::HTTP).to receive(:new).exactly(3).times.and_return(upload_url_http, upload_http, register_http)

    described_class.update_app_localization_info(token, params)

    expect(request_order).to eq([:upload_url, :upload, :register])
  end

  it "preserves lexicographic screenshot order when registering files" do
    write_file(File.join(metadata_path, "en-US", "screenshots", "10.png"), "ten")
    write_file(File.join(metadata_path, "en-US", "screenshots", "02.png"), "two")

    upload_url_one = http_client do |_request|
      http_response(body: { uploadUrl: "https://upload.example.com/files/1", authCode: "auth-1" }.to_json)
    end

    upload_one = http_client do |request|
      expect(request.body).to include("filename=\"02.png\"")
      http_response(
        body: {
          result: {
            UploadFileRsp: {
              fileInfoList: [{
                fileDestUlr: "screenshots/02.png",
                size: "3",
                imageResolution: "1080x1920",
                imageResolutionSingature: "sig-02"
              }]
            }
          }
        }.to_json
      )
    end

    upload_url_two = http_client do |_request|
      http_response(body: { uploadUrl: "https://upload.example.com/files/2", authCode: "auth-2" }.to_json)
    end

    upload_two = http_client do |request|
      expect(request.body).to include("filename=\"10.png\"")
      http_response(
        body: {
          result: {
            UploadFileRsp: {
              fileInfoList: [{
                fileDestUlr: "screenshots/10.png",
                size: "3",
                imageResolution: "1080x1920",
                imageResolutionSingature: "sig-10"
              }]
            }
          }
        }.to_json
      )
    end

    register_http = http_client do |request|
      body = JSON.parse(request.body)
      expect(body["files"].map { |file| file["fileName"] }).to eq(["02.png", "10.png"])
      http_response(body: { ret: { code: 0 } }.to_json)
    end

    expect(Net::HTTP).to receive(:new).exactly(5).times.and_return(upload_url_one, upload_one, upload_url_two, upload_two, register_http)

    described_class.update_app_localization_info(token, params)
  end

  it "treats an empty screenshots folder as a no-op" do
    FileUtils.mkdir_p(File.join(metadata_path, "en-US", "screenshots"))

    expect(Net::HTTP).not_to(receive(:new))

    described_class.update_app_localization_info(token, params)
  end

  it "treats a missing screenshots folder as a no-op" do
    FileUtils.mkdir_p(File.join(metadata_path, "en-US"))

    expect(Net::HTTP).not_to(receive(:new))

    described_class.update_app_localization_info(token, params)
  end

  it "raises a user-facing error for unsupported screenshot extensions" do
    write_file(File.join(metadata_path, "en-US", "screenshots", "01.webp"), "webp-data")

    expect do
      described_class.update_app_localization_info(token, params)
    end.to raise_error(FastlaneCore::Interface::FastlaneError, /Unsupported screenshot format/)
  end

  it "updates only locales that provide screenshot assets" do
    write_file(File.join(metadata_path, "en-US", "screenshots", "01.png"), "png-data")
    FileUtils.mkdir_p(File.join(metadata_path, "fr-FR"))

    register_languages = []

    upload_url_http = http_client do |_request|
      http_response(body: { uploadUrl: "https://upload.example.com/files", authCode: "auth-1" }.to_json)
    end

    upload_http = http_client do |_request|
      http_response(
        body: {
          result: {
            UploadFileRsp: {
              fileInfoList: [{
                fileDestUlr: "screenshots/01.png",
                size: "8",
                imageResolution: "1080x1920",
                imageResolutionSingature: "sig-1"
              }]
            }
          }
        }.to_json
      )
    end

    register_http = http_client do |request|
      register_languages << JSON.parse(request.body)["lang"]
      http_response(body: { ret: { code: 0 } }.to_json)
    end

    expect(Net::HTTP).to receive(:new).exactly(3).times.and_return(upload_url_http, upload_http, register_http)

    described_class.update_app_localization_info(token, params)

    expect(register_languages).to eq(["en-US"])
  end
end
