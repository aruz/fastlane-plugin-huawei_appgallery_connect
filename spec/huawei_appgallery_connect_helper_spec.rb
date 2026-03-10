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

  def success_response
    http_response(body: { ret: { code: 0 } }.to_json)
  end

  def upload_url_response(options)
    http_response(
      body: {
        uploadUrl: options.fetch(:upload_url),
        authCode: options.fetch(:auth_code),
        objectId: options.fetch(:object_id)
      }.to_json
    )
  end

  def upload_file_response(options)
    http_response(
      body: {
        result: {
          UploadFileRsp: {
            fileInfoList: [
              {
                imageResolution: options.fetch(:image_resolution)
              }
            ]
          }
        }
      }.to_json
    )
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
      expect(JSON.parse(request.body)).to eq(
        "lang" => "en-US",
        "appName" => "Example App",
        "appDesc" => "Description",
        "briefInfo" => "Brief",
        "newFeatures" => "Notes"
      )

      success_response
    end

    expect(Net::HTTP).to receive(:new).once.and_return(text_http)

    described_class.update_app_localization_info(token, params)
  end

  it "uploads screenshots using upload-url, file upload, and app-file-info in order" do
    screenshot_directory = File.join(metadata_path, "en-US", "screenshots")
    write_file(File.join(screenshot_directory, "01-home.png"), "png-one")
    write_file(File.join(screenshot_directory, "02-details.png"), "png-two")
    allow(Fastlane::UI).to receive(:important)

    events = []
    upload_url_http_1 = http_client do |request|
      events << "upload-url:1"
      expect(request).to be_a(Net::HTTP::Get)
      expect(request.path).to eq("/api/publish/v2/upload-url?appId=app-id&suffix=png")

      upload_url_response(
        upload_url: "https://upload.example.com/files/1",
        auth_code: "auth-1",
        object_id: "object-1"
      )
    end
    upload_http_1 = http_client do |request|
      events << "upload:1"
      expect(request).to be_a(Net::HTTP::Post)
      expect(request.path).to eq("/files/1")
      expect(request["Content-Type"]).to start_with("multipart/form-data; boundary=")
      expect(request.body).to include('name="authCode"')
      expect(request.body).to include("auth-1")
      expect(request.body).to include('name="parseType"')
      expect(request.body).to include('filename="01-home.png"')

      upload_file_response(image_resolution: "1080*1920")
    end
    upload_url_http_2 = http_client do |request|
      events << "upload-url:2"
      expect(request).to be_a(Net::HTTP::Get)
      expect(request.path).to eq("/api/publish/v2/upload-url?appId=app-id&suffix=png")

      upload_url_response(
        upload_url: "https://upload.example.com/files/2",
        auth_code: "auth-2",
        object_id: "object-2"
      )
    end
    upload_http_2 = http_client do |request|
      events << "upload:2"
      expect(request).to be_a(Net::HTTP::Post)
      expect(request.path).to eq("/files/2")
      expect(request["Content-Type"]).to start_with("multipart/form-data; boundary=")
      expect(request.body).to include('name="authCode"')
      expect(request.body).to include("auth-2")
      expect(request.body).to include('filename="02-details.png"')

      upload_file_response(image_resolution: "1080*1920")
    end
    register_http = http_client do |request|
      events << "register"
      expect(request).to be_a(Net::HTTP::Put)
      expect(request.path).to eq("/api/publish/v2/app-file-info?appId=app-id")
      expect(JSON.parse(request.body)).to eq(
        "fileType" => 2,
        "files" => [
          { "fileDestUrl" => "object-1" },
          { "fileDestUrl" => "object-2" }
        ],
        "lang" => "en-US",
        "imgShowType" => 0
      )

      success_response
    end

    expect(Net::HTTP).to receive(:new).exactly(5).times.and_return(
      upload_url_http_1,
      upload_http_1,
      upload_url_http_2,
      upload_http_2,
      register_http
    )

    described_class.update_app_localization_info(token, params)

    expect(events).to eq(["upload-url:1", "upload:1", "upload-url:2", "upload:2", "register"])
  end

  it "preserves lexicographic filename order for multiple screenshots" do
    screenshot_directory = File.join(metadata_path, "en-US", "screenshots")
    write_file(File.join(screenshot_directory, "10-last.png"), "png-ten")
    write_file(File.join(screenshot_directory, "02-middle.png"), "png-two")
    write_file(File.join(screenshot_directory, "01-first.png"), "png-one")
    allow(Fastlane::UI).to receive(:important)

    upload_url_http_1 = http_client do |_request|
      upload_url_response(
        upload_url: "https://upload.example.com/files/1",
        auth_code: "auth-1",
        object_id: "object-01"
      )
    end
    upload_http_1 = http_client do |request|
      expect(request.body).to include('filename="01-first.png"')
      upload_file_response(image_resolution: "1080*1920")
    end
    upload_url_http_2 = http_client do |_request|
      upload_url_response(
        upload_url: "https://upload.example.com/files/2",
        auth_code: "auth-2",
        object_id: "object-02"
      )
    end
    upload_http_2 = http_client do |request|
      expect(request.body).to include('filename="02-middle.png"')
      upload_file_response(image_resolution: "1080*1920")
    end
    upload_url_http_3 = http_client do |_request|
      upload_url_response(
        upload_url: "https://upload.example.com/files/3",
        auth_code: "auth-3",
        object_id: "object-10"
      )
    end
    upload_http_3 = http_client do |request|
      expect(request.body).to include('filename="10-last.png"')
      upload_file_response(image_resolution: "1080*1920")
    end
    register_http = http_client do |request|
      expect(JSON.parse(request.body)).to include(
        "files" => [
          { "fileDestUrl" => "object-01" },
          { "fileDestUrl" => "object-02" },
          { "fileDestUrl" => "object-10" }
        ]
      )

      success_response
    end

    expect(Net::HTTP).to receive(:new).exactly(7).times.and_return(
      upload_url_http_1,
      upload_http_1,
      upload_url_http_2,
      upload_http_2,
      upload_url_http_3,
      upload_http_3,
      register_http
    )

    described_class.update_app_localization_info(token, params)
  end

  it "still updates text metadata when a locale also contains screenshots" do
    locale_path = File.join(metadata_path, "en-US")
    write_file(File.join(locale_path, "app_name"), "Example App")
    write_file(File.join(locale_path, "screenshots", "01.png"), "png-data")
    allow(Fastlane::UI).to receive(:important)

    events = []
    text_http = http_client do |request|
      events << "text"
      expect(JSON.parse(request.body)).to include("lang" => "en-US", "appName" => "Example App")
      success_response
    end
    upload_url_http = http_client do |_request|
      events << "upload-url"
      upload_url_response(
        upload_url: "https://upload.example.com/files/1",
        auth_code: "auth-1",
        object_id: "object-1"
      )
    end
    upload_http = http_client do |_request|
      events << "upload"
      upload_file_response(image_resolution: "1080*1920")
    end
    register_http = http_client do |request|
      events << "register"
      expect(JSON.parse(request.body)).to include(
        "fileType" => 2,
        "lang" => "en-US",
        "imgShowType" => 0
      )
      success_response
    end

    expect(Net::HTTP).to receive(:new).exactly(4).times.and_return(
      text_http,
      upload_url_http,
      upload_http,
      register_http
    )

    described_class.update_app_localization_info(token, params)

    expect(events).to eq(["text", "upload-url", "upload", "register"])
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

  it "fails fast on unsupported screenshot extensions" do
    write_file(File.join(metadata_path, "en-US", "screenshots", "01.gif"), "gif-data")

    expect(Net::HTTP).not_to(receive(:new))

    expect do
      described_class.update_app_localization_info(token, params)
    end.to raise_error(/Unsupported screenshot format for en-US: 01.gif/)
  end

  it "updates screenshots for one locale without affecting locales that have no screenshot assets" do
    write_file(File.join(metadata_path, "de-DE", "app_name"), "Beispiel")
    write_file(File.join(metadata_path, "en-US", "screenshots", "01.png"), "png-data")
    allow(Fastlane::UI).to receive(:important)

    events = []
    text_http = http_client do |request|
      events << "text:de-DE"
      expect(JSON.parse(request.body)).to include("lang" => "de-DE", "appName" => "Beispiel")
      success_response
    end
    upload_url_http = http_client do |_request|
      events << "upload-url:en-US"
      upload_url_response(
        upload_url: "https://upload.example.com/files/1",
        auth_code: "auth-1",
        object_id: "object-1"
      )
    end
    upload_http = http_client do |_request|
      events << "upload:en-US"
      upload_file_response(image_resolution: "1080*1920")
    end
    register_http = http_client do |request|
      events << "register:en-US"
      expect(JSON.parse(request.body)).to include("lang" => "en-US", "imgShowType" => 0)
      success_response
    end

    expect(Net::HTTP).to receive(:new).exactly(4).times.and_return(
      text_http,
      upload_url_http,
      upload_http,
      register_http
    )

    described_class.update_app_localization_info(token, params)

    expect(events).to eq(["text:de-DE", "upload-url:en-US", "upload:en-US", "register:en-US"])
  end
end
