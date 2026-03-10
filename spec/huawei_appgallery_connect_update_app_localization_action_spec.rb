require "spec_helper"

describe Fastlane::Actions::HuaweiAppgalleryConnectUpdateAppLocalizationAction do
  let(:configuration) do
    FastlaneCore::Configuration.create(
      described_class.available_options,
      client_id: "client-id",
      client_secret: "client-secret",
      app_id: "app-id",
      metadata_path: "fastlane/metadata/huawei"
    )
  end

  it "fetches a token and delegates localization updates to the helper" do
    allow(Fastlane::Helper::HuaweiAppgalleryConnectHelper).to receive(:get_token).with("client-id", "client-secret").and_return("token-123")
    expect(Fastlane::Helper::HuaweiAppgalleryConnectHelper).to receive(:update_app_localization_info).with("token-123", configuration)

    described_class.run(configuration)
  end

  it "prints a message when the token cannot be retrieved" do
    allow(Fastlane::Helper::HuaweiAppgalleryConnectHelper).to receive(:get_token).and_return(nil)
    expect(Fastlane::UI).to receive(:message).with("Cannot retrieve token, please check your client ID and client secret")

    described_class.run(configuration)
  end
end
