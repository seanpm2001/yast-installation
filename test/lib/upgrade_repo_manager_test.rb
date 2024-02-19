#! /usr/bin/env rspec

require_relative "../test_helper"
require "installation/upgrade_repo_manager"

begin
  # check if the registration package is present, it might not be available during RPM build
  require "registration/registration"
rescue LoadError
  # mock the Registration class if missing
  module Registration
    class Registration
      def self.is_registered?
        false
      end
    end
  end
end

describe Installation::UpgradeRepoManager do
  let(:repo1) do
    Y2Packager::Repository.new(repo_id: 1, repo_alias: "test1",
      url: URI("https://example.com/1"), raw_url: URI("https://example.com/1"),
      name: "repo1", enabled: true, autorefresh: true)
  end

  let(:repo2) do
    Y2Packager::Repository.new(repo_id: 2, repo_alias: "test2",
      url: URI("https://example.com/2"), raw_url: URI("https://example.com/2"),
      name: "repo2", enabled: true, autorefresh: true)
  end

  let(:extra_repo) do
    Y2Packager::Repository.new(repo_id: 42, repo_alias: "extra",
      url: URI("https://example.com/extra"), raw_url: URI("https://example.com/extra"),
      name: "extra", enabled: true, autorefresh: true)
  end

  let(:service1) do
    Y2Packager::Service.new(service_alias: "service1", name: "service1",
      url: "https://example.com/service", enabled: true, auto_refresh: true)
  end

  subject { Installation::UpgradeRepoManager.new([repo1, repo2], [service1]) }

  describe "#repo_status" do
    it "preselects all repositories to remove" do
      expect(subject.repo_status(repo1)).to eq(:removed)
      expect(subject.repo_status(repo2)).to eq(:removed)
    end

    it "returns `nil` for unknown repositories" do
      expect(subject.repo_status(extra_repo)).to be_nil
    end
  end

  describe "#repo_url" do
    it "returns the original raw URL if it has not been changed" do
      expect(subject.repo_url(repo1)).to eq(repo1.raw_url.to_s)
    end

  end

  describe "#change_url" do
    it "changes the repository" do
      new_url = "https://example.com/new"
      subject.change_url(repo1, new_url)
      expect(subject.repo_url(repo1)).to eq(new_url)
    end
  end

  describe "#toggle_repo_status" do
    it "changes the :removed status to :enabled" do
      expect { subject.toggle_repo_status(repo1) }.to change { subject.repo_status(repo1) }
        .from(:removed).to(:enabled)
    end

    it "changes the :enabled status to :disabled" do
      # call toggle to switch the internal state to the requested value
      subject.toggle_repo_status(repo1)
      expect { subject.toggle_repo_status(repo1) }.to change { subject.repo_status(repo1) }
        .from(:enabled).to(:disabled)
    end

    it "changes the :disabled status to :removed" do
      # call toggle to switch the internal state to the requested value
      subject.toggle_repo_status(repo1)
      subject.toggle_repo_status(repo1)
      expect { subject.toggle_repo_status(repo1) }.to change { subject.repo_status(repo1) }
        .from(:disabled).to(:removed)
    end
  end

  describe "#activate_changes" do
    before do
      allow(repo1).to receive(:enable!)
      allow(repo1).to receive(:disable!)
      allow(repo1).to receive(:delete!)
      allow(Yast::Pkg).to receive(:ServiceDelete)
      allow(Yast::Pkg).to receive(:SourceSaveAll)
      allow(Yast::Pkg).to receive(:SourceFinishAll)
      allow(Yast::Pkg).to receive(:SourceRestore)
      allow(Yast::Pkg).to receive(:SourceLoad)
      allow(Y2Packager::Resolvable).to receive(:find).and_return([])
    end

    it "removes the selected repositories" do
      expect(repo1).to receive(:delete!)
      expect(repo2).to receive(:delete!)
      subject.activate_changes
    end

    it "enables the selected repositories" do
      subject.toggle_repo_status(repo1)
      expect(repo1).to receive(:enable!)
      subject.activate_changes
    end

    it "disables the selected repositories" do
      subject.toggle_repo_status(repo1)
      subject.toggle_repo_status(repo1)
      expect(repo1).to receive(:disable!)
      subject.activate_changes
    end

    it "updates the URLs of changed repositories" do
      new_url = "https://example.com/new"
      subject.change_url(repo1, new_url)
      expect(repo1).to receive(:url=).with(new_url)
      subject.activate_changes
    end

    it "removes the old services" do
      expect(Yast::Pkg).to receive(:ServiceDelete).with(service1.alias)
      subject.activate_changes
    end

    it "restores the selected products" do
      product = double(name: "SLES", kind: :product)
      expect(Y2Packager::Resolvable).to receive(:find)
        .with(status: :selected, transact_by: :appl_high).and_return([product])
      expect(Yast::Pkg).to receive(:ResolvableInstall)
        .with(product.name, product.kind).and_return(true)
      subject.activate_changes
    end
  end

  describe ".create_from_old_repositories" do
    before do
      allow(Y2Packager::Repository).to receive(:all).and_return([repo1, repo2])
      allow(Y2Packager::Service).to receive(:all).and_return([])
      allow(Y2Packager::OriginalRepositorySetup.instance).to receive(:repositories)
        .and_return([repo1, repo2])
      allow(Y2Packager::OriginalRepositorySetup.instance).to receive(:services)
        .and_return([])
      allow(Registration::Registration).to receive(:is_registered?).and_return(false)
      allow(Y2Packager::NewRepositorySetup.instance).to receive(:services).and_return([])
      allow(Y2Packager::NewRepositorySetup.instance).to receive(:repositories).and_return([])
    end

    it "initializes the UpgradeRepoManager from the stored old repositories" do
      old_repo_manager = Installation::UpgradeRepoManager.create_from_old_repositories
      expect(old_repo_manager.repositories).to eq([repo1, repo2])
    end

    it "skips the already removed repositories" do
      # make only repo1 currently available
      allow(Y2Packager::Repository).to receive(:all).and_return([repo1])
      old_repo_manager = Installation::UpgradeRepoManager.create_from_old_repositories
      expect(old_repo_manager.repositories).to eq([repo1])
    end

    it "does not remove the new services with same name as an old service" do
      expect(Y2Packager::NewRepositorySetup.instance).to receive(:services)
        .and_return([service1.name])
      expect(Y2Packager::OriginalRepositorySetup.instance).to receive(:services)
        .and_return([service1])

      upgrade_repo_manager = Installation::UpgradeRepoManager.create_from_old_repositories

      # empty result as the old service has the same name as the new service
      # so it is not deleted
      expect(upgrade_repo_manager.services).to eq([])
    end
  end
end
