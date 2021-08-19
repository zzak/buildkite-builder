# frozen_string_literal: true

RSpec.describe Buildkite::Builder::Pipeline do
  before do
    setup_project(fixture_project)
  end
  let(:fixture_project) { :basic }
  let(:fixture_path) { fixture_pipeline_path_for(fixture_project, :dummy) }

  describe '.build' do
    it 'initializes and builds the pipeline' do
      pipeline = described_class.build(fixture_path)

      expect(pipeline).to be_a(Buildkite::Builder::Pipeline)
    end
  end

  describe '.new' do
    let(:pipeline) { described_class.new(fixture_path) }

    it 'sets attributes' do
      logger = Logger.new(STDOUT)
      pipeline = described_class.new(fixture_path, logger: logger)

      expect(pipeline.root).to eq(fixture_path)
      expect(pipeline.logger).to eq(logger)
    end

    it 'loads manifests' do
      expect(pipeline).to be_a(Buildkite::Builder::Pipeline)
      manifests = Buildkite::Builder::Manifest.manifests

      expect(manifests.size).to eq(1)
      expect(manifests).to have_key('basic')
      expect(manifests['basic']).to be_a(Buildkite::Builder::Manifest)
    end

    it 'loads the pipeline' do
      pipeline_data = YAML.load(pipeline.to_yaml)

      expect(pipeline_data.dig('steps', 0, 'label')).to eq('Basic step')
    end

    it 'loads extensions' do
      expect(Buildkite::Builder::Loaders::Extensions).to receive(:load).with(fixture_path)

      pipeline
    end
  end

  describe '#upload' do
    let(:pipeline) { described_class.new(fixture_path) }

    it 'sets pipeline and uploads to Buildkite' do
      artifact_path = nil
      pipeline_path = nil
      artifact_contents = nil
      pipeline_contents = nil

      expect(Buildkite::Pipelines::Command).to receive(:artifact!).ordered do |subcommand, path|
        expect(subcommand).to eq(:upload)
        artifact_path = path
        artifact_contents = File.read(path)
      end

      expect(Buildkite::Pipelines::Command).to receive(:pipeline!).ordered do |subcommand, path|
        expect(subcommand).to eq(:upload)
        pipeline_path = path
        pipeline_contents = File.read(path)
      end

      pipeline.upload

      expect(File.exist?(artifact_path)).to eq(false)
      expect(File.exist?(pipeline_path)).to eq(false)
      expect(artifact_contents).to eq(pipeline_contents)
      expect(pipeline_contents).to eq(<<~YAML)
        ---
        steps:
        - label: Basic step
          command:
          - 'true'
      YAML
    end

    context 'when has custom artifacts to upload' do
      let(:bar) do
        { bar: :baz }.to_json
      end

      let(:dummy_file) { File.open(Pathname.new('spec/fixtures/dummy_artifact')) }

      before do
        # Existing file
        pipeline.artifacts << dummy_file.path

        # Tempfile on the fly
        tempfile = Tempfile.new('bar.json')
        tempfile.sync = true
        tempfile.write(bar)
        pipeline.artifacts << tempfile.path
      end

      it 'uploads custom artifacts' do
        artifact_paths = []
        artifact_contents = {}

        # 2 custom files, 1 pipeline.yml
        expect(Buildkite::Pipelines::Command).to receive(:artifact!).exactly(3).times do |subcommand, path|
          expect(subcommand).to eq(:upload)
          artifact_contents[path] = File.read(path)
        end

        expect(Buildkite::Pipelines::Command).to receive(:pipeline!).ordered do |subcommand, path|
          expect(subcommand).to eq(:upload)
          pipeline_path = path
          pipeline_contents = File.read(path)
        end

        pipeline.upload

        artifact_contents.each do |filename, content|
          if filename =~ /dummy_artifact/
            expect(content).to eq(dummy_file.read)
          elsif filename =~ /bar.json/
            expect(content).to eq(bar)
          elsif filename =~ /pipeline.yml/
            expect(content).to eq(<<~YAML)
              ---
              steps:
              - label: Basic step
                command:
                - 'true'
            YAML
          end
        end
      end
    end
  end

  context 'serialization' do
    describe '#to_h' do
      context 'when valid' do
        let(:pipeline) { described_class.new(fixture_path) }
        let!(:payload) do
          {
            'steps' => [
              { 'command' => ['foo-command'] },
              { 'trigger' => 'foo-trigger' },
              { 'wait' => nil, 'continue_on_failure' => true },
              { 'block' => 'foo-block' },
              { 'input' => 'foo-block' },
              { 'skip' => 'foo-block', 'command' => nil },
              { 'command' => ['true'], 'label' => 'Basic step' },
            ]
          }
        end

        before do
          pipeline.dsl.instance_eval do
            command { command('foo-command') }
            trigger { trigger('foo-trigger') }
            wait(continue_on_failure: true)
            block { block('foo-block') }
            input { input('foo-block') }
            skip { skip('foo-block') }
          end
        end

        context 'when env is specified' do
          before do
            pipeline.dsl.instance_eval do
              env(FOO: 'foo')
            end
          end

          it 'includes the env key' do
            expect(pipeline.to_h).to eq(
              payload.merge(
                'env' => {
                  'FOO' => 'foo',
                }
              )
            )
          end
        end

        it 'builds the pipeline hash' do
          expect(pipeline.to_h).to eq(payload)
        end
      end

      context 'with an invalid step' do
        let(:fixture_project) { :invalid_step }

        it 'raises an error' do
          expect {
            described_class.new(fixture_path).to_h
          }.to raise_error(/must return a valid definition \(Buildkite::Builder::Definition::Template\)/)
        end
      end

      context 'with an invalid pipeline' do
        let(:fixture_project) { :invalid_pipeline }

        it 'raises an error' do
          expect {
            described_class.new(fixture_path).to_h
          }.to raise_error(/must return a valid definition \(Buildkite::Builder::Definition::Pipeline\)/)
        end
      end
    end

    describe '#to_yaml' do
      let(:pipeline) { described_class.new(fixture_path) }

      it 'dumps the pipeline to yaml' do
        expect(pipeline.to_yaml).to eq(YAML.dump(pipeline.to_h))
      end
    end
  end
end
