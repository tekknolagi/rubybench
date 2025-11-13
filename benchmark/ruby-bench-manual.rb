#!/usr/bin/env ruby
# Script to manually run benchmarks for a specific date
require 'fileutils'
require 'json'
require 'yaml'
require 'optparse'

# Parse command-line arguments
options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: ruby-bench-manual.rb [options] benchmark_name"

  opts.on("-d", "--date DATE", "Target date (YYYYMMDD format)") do |d|
    options[:date] = d
  end

  opts.on("-f", "--force", "Force re-run even if results exist") do
    options[:force] = true
  end

  opts.on("-r", "--ractor", "Run as ractor benchmark") do
    options[:ractor] = true
  end

  opts.on("--ractor-only", "Run as ractor-only benchmark") do
    options[:ractor_only] = true
  end

  opts.on("-l", "--list", "List available benchmarks") do
    options[:list] = true
  end

  opts.on("-h", "--help", "Show this help message") do
    puts opts
    puts "\nExamples:"
    puts "  # List all available benchmarks"
    puts "  ./ruby-bench-manual.rb -l"
    puts ""
    puts "  # Run a regular benchmark for a specific date"
    puts "  ./ruby-bench-manual.rb -d 20250815 activerecord"
    puts ""
    puts "  # Force re-run even if results exist"
    puts "  ./ruby-bench-manual.rb -d 20250815 --force activerecord"
    puts ""
    puts "  # Run a ractor-compatible benchmark"
    puts "  ./ruby-bench-manual.rb -d 20250815 --ractor erubi"
    puts ""
    puts "  # Run a ractor-only benchmark"
    puts "  ./ruby-bench-manual.rb -d 20250815 --ractor-only knucleotide"
    exit
  end
end.parse!

# Handle list option
if options[:list]
  benchmarks_yml = YAML.load_file('benchmark/ruby-bench/benchmarks.yml')

  puts "\n=== Regular Benchmarks ==="
  benchmarks_yml.keys.sort.each do |name|
    puts "  #{name}"
  end

  puts "\n=== Ractor-Compatible Benchmarks ==="
  benchmarks_yml.select { |_, info| info['ractor'] == true }.keys.sort.each do |name|
    puts "  #{name} (ractor-compatible)"
  end

  puts "\n=== Ractor-Only Benchmarks ==="
  Dir.glob('benchmark/ruby-bench/benchmarks-ractor/**/benchmark.rb').each do |path|
    puts "  #{File.basename(File.dirname(path))} (ractor-only)"
  end

  exit 0
end

if ARGV.empty? && !options[:list]
  puts "Error: Please specify a benchmark name"
  exit 1
end

if options[:date].nil? && !options[:list]
  puts "Error: Please specify a date with -d or --date"
  exit 1
end

# Manual benchmark runner class
class ManualBenchmarkRunner
  RACTOR_ITERATION_PATTERN = /^\s*(\d+)\s+#\d+:\s*(\d+)ms/

  def initialize
    @started_containers = []
    rubies_path = File.expand_path('../results/rubies.yml', __dir__)
    unless File.exist?(rubies_path)
      abort "ERROR: rubies.yml not found at #{rubies_path}"
    end
    @rubies = YAML.load_file(rubies_path)
  end

  def shutdown
    @started_containers.each do |container|
      system('docker', 'rm', '-f', container, exception: true, err: File::NULL)
    end
  end

  def run_regular_benchmark(benchmark, target_date, force: false)
    results_file = "results/ruby-bench/#{benchmark}.yml"
    memory_results_file = results_file.sub('.yml', '_memory.yml')

    # Load existing results
    results = File.exist?(results_file) ? YAML.load_file(results_file) : {}
    memory_results = File.exist?(memory_results_file) ? YAML.load_file(memory_results_file) : {}

    # Check if date exists
    unless @rubies.key?(target_date)
      puts "Error: Date #{target_date} not found in rubies.yml"
      puts "Available dates: #{@rubies.keys.sort.first}..#{@rubies.keys.sort.last}"
      exit 1
    end

    # Check if already benchmarked
    if results.key?(target_date) && !force
      puts "Benchmark for #{target_date} already exists. Use --force to re-run."
      puts "Existing results: #{results[target_date]}"
      exit 0
    end

    puts "Running #{benchmark} for date: #{target_date}"
    puts "Ruby SHA: #{@rubies[target_date]}"

    # Set up container and run benchmarks
    container = setup_container(target_date, benchmark)
    result = []
    memory_result = []
    timeout = 10 * 60

    [nil, '--yjit', '--zjit'].each do |opts|
      jit_name = opts.nil? ? 'no-jit' : opts
      puts "\nRunning with #{jit_name}..."

      env = "env BUNDLE_JOBS=8"
      cmd = [
        'docker', 'exec', container, 'bash', '-c',
        "cd /rubybench/benchmark/ruby-bench && #{env} timeout --signal=KILL #{timeout} ./run_benchmarks.rb #{benchmark} --rss -e 'ruby #{opts}'",
      ]
      out = IO.popen(cmd, &:read)
      puts out

      if $?.success?
        if line = find_benchmark_line(out, benchmark)
          value = Float(line.split(/\s+/)[1])
          result << value
          puts "Result: #{value}"
        else
          puts "benchmark output for #{benchmark} not found"
          result << nil
        end

        # Parse memory data
        if rss = parse_memory_output(out)
          memory_result << rss
          puts "Memory: #{rss / 1024.0 / 1024.0} MiB"
        else
          memory_result << nil
        end
      else
        result << nil
        memory_result << nil
        puts "Benchmark failed!"
      end
    end

    # Update results
    results[target_date] = result
    memory_results[target_date] = memory_result

    # Write results
    FileUtils.mkdir_p(File.dirname(results_file))
    File.open(results_file, "w") do |io|
      results.sort_by(&:first).each do |date, values|
        io.puts "#{date}: #{values.to_json}"
      end
    end

    File.open(memory_results_file, "w") do |io|
      memory_results.sort_by(&:first).each do |date, values|
        io.puts "#{date}: #{values.to_json}"
      end
    end

    # Clean up
    system('docker', 'exec', container, 'git', 'config', '--global', '--add', 'safe.directory', '*', exception: true)
    system('docker', 'exec', container, 'git', '-C', '/rubybench/benchmark/ruby-bench', 'clean', '-dfx', exception: true)

    puts "\nResults written to: #{results_file}"
    puts "Memory results written to: #{memory_results_file}"
    puts "Final results: #{result.inspect}"
  end

  def run_ractor_benchmark(benchmark, target_date, force: false, ractor_only: false)
    safe_name = benchmark.gsub('/', '_')
    prefix = ractor_only ? "ractor_only_" : ""
    results_file = "results/ruby-bench-ractor/#{prefix}#{safe_name}.yml"
    category = ractor_only ? 'ractor-only' : 'ractor'

    # Load existing results
    results = File.exist?(results_file) ? YAML.load_file(results_file) : {}

    # Check if date exists
    unless @rubies.key?(target_date)
      puts "Error: Date #{target_date} not found in rubies.yml"
      puts "Available dates: #{@rubies.keys.sort.first}..#{@rubies.keys.sort.last}"
      exit 1
    end

    # Check if already benchmarked
    if results.key?(target_date) && !force
      puts "Ractor benchmark for #{target_date} already exists. Use --force to re-run."
      puts "Existing results: #{results[target_date]}"
      exit 0
    end

    puts "Running ractor:#{benchmark} for date: #{target_date}"
    puts "Ruby SHA: #{@rubies[target_date]}"
    puts "Category: #{category}"

    # Set up container and run benchmarks
    container = setup_container(target_date, benchmark)
    result = {}
    timeout = 10 * 60

    [nil, '--yjit', '--zjit'].each do |opts|
      config_name = opts.nil? ? 'baseline' : opts.delete_prefix('--')
      jit_name = opts.nil? ? 'baseline' : opts
      puts "\nRunning with #{jit_name}..."

      env = "env BUNDLE_JOBS=8"
      cmd = [
        'docker', 'exec', container, 'bash', '-c',
        "cd /rubybench/benchmark/ruby-bench && #{env} timeout --signal=KILL #{timeout} ./run_benchmarks.rb #{benchmark} --category #{category} --rss -e 'ruby #{opts}'",
      ]
      out = IO.popen(cmd, &:read)
      puts out

      if $?.success?
        parsed = parse_ractor_output(out, benchmark)
        result[config_name] = parsed
        puts "Result: #{parsed.inspect}"
      else
        result[config_name] = nil
        puts "Benchmark failed!"
      end
    end

    # Update results
    results[target_date] = result

    # Write results
    FileUtils.mkdir_p(File.dirname(results_file))
    File.open(results_file, "w") do |io|
      results.sort_by(&:first).each do |date, values|
        io.puts "#{date}: #{values.to_json}"
      end
    end

    # Clean up
    system('docker', 'exec', container, 'git', 'config', '--global', '--add', 'safe.directory', '*', exception: true)
    system('docker', 'exec', container, 'git', '-C', '/rubybench/benchmark/ruby-bench', 'clean', '-dfx', exception: true)

    puts "\nResults written to: #{results_file}"
    puts "Final results: #{result.inspect}"
  end

  private

  def setup_container(target_date, benchmark)
    container = "rubybench-#{target_date}"

    unless @started_containers.include?(container)
      system('docker', 'rm', '-f', container, exception: true, err: File::NULL)
      system(
        'docker', 'run', '-d', '--privileged', '--name', container,
        '-v', "#{Dir.pwd}:/rubybench",
        "ghcr.io/ruby/ruby:master-#{@rubies.fetch(target_date)}",
        'bash', '-c', 'while true; do sleep 100000; done',
        exception: true,
      )
      cmd = 'apt-get update && apt install -y build-essential git libsqlite3-dev libyaml-dev nodejs pkg-config sudo xz-utils'
      system('docker', 'exec', container, 'bash', '-c', cmd, exception: true)
      @started_containers << container
    end

    container
  end

  def find_benchmark_line(output, benchmark)
    search_pattern = benchmark.include?('/') ? benchmark.split('/').last : benchmark
    output.lines.reverse.find { |line| line.start_with?(search_pattern) }
  end

  def parse_memory_output(output)
    # Look for RSS output in the format: RSS: 123.4MiB
    # or MAXRSS: 456.7MiB (prefer MAXRSS if available)
    maxrss_line = output.lines.find { |line| line.include?("MAXRSS:") }
    rss_line = output.lines.find { |line| line.include?("RSS:") }

    # Prefer MAXRSS over RSS
    target_line = maxrss_line || rss_line
    return nil unless target_line

    # Extract the value in MiB and convert to bytes
    if match = target_line.match(/(?:MAX)?RSS:\s*(\d+(?:\.\d+)?)\s*MiB/)
      mib_value = match[1].to_f
      return (mib_value * 1024 * 1024).to_i  # Convert MiB to bytes
    end

    nil
  end

  def parse_ractor_output(output, benchmark)
    grouped = {}

    iteration_lines = output.lines.select { |line| line.match(RACTOR_ITERATION_PATTERN) }
    return nil if iteration_lines.empty?

    iteration_lines.each do |line|
      if match = line.match(RACTOR_ITERATION_PATTERN)
        ractor_count = match[1]
        time_ms = match[2].to_f

        grouped[ractor_count] ||= []
        grouped[ractor_count] << time_ms
      end
    end

    return nil if grouped.empty?
    grouped
  end
end

# Run the benchmark
benchmark = ARGV[0]
target_date = options[:date]
force = options[:force] || false
is_ractor = options[:ractor] || false
is_ractor_only = options[:ractor_only] || false

runner = ManualBenchmarkRunner.new
at_exit { runner.shutdown }

if is_ractor || is_ractor_only
  # Run as ractor benchmark
  runner.run_ractor_benchmark(benchmark, target_date, force: force, ractor_only: is_ractor_only)
else
  # Run as regular benchmark
  runner.run_regular_benchmark(benchmark, target_date, force: force)
end