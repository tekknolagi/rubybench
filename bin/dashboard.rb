#!/usr/bin/env ruby
require 'yaml'

def format_float(float)
  ('%0.2f' % float).to_f
end

# 20250908 -> "2025-09-08"
def to_date(ruby)
  year = ruby / 10000
  month = ruby / 100 % 100
  day = ruby % 100
  "%04d-%02d-%02d" % [year, month, day]
end

rubies_path = File.expand_path('../results/rubies.yml', __dir__)
unless File.exist?(rubies_path)
  abort "ERROR: rubies.yml not found at #{rubies_path}. Please setup using bin/prepare-results.rb"
end
rubies = YAML.load_file(rubies_path).keys
benchmarks = YAML.load_file(File.expand_path('../benchmark/ruby-bench/benchmarks.yml', __dir__), symbolize_names: true)
# TODO(max): Remove this filter when Ractor benchmarks are meant to be run by default
benchmarks.select! {|benchmark, _| !benchmark.to_s.include? 'ractor/'}
benchmark_results = benchmarks.map do |benchmark, _|
  [benchmark, YAML.load_file(File.expand_path("../results/ruby-bench/#{benchmark}.yml", __dir__))]
end.to_h

# Load memory results
memory_results = benchmarks.map do |benchmark, _|
  memory_file = File.expand_path("../results/ruby-bench/#{benchmark}_memory.yml", __dir__)
  if File.exist?(memory_file)
    [benchmark, YAML.load_file(memory_file)]
  else
    [benchmark, {}]
  end
end.to_h

ruby = rubies.select { |ruby| benchmark_results.first.last.key?(ruby) }.max
dashboard = {
  date: to_date(ruby),
  headline: {
    no_jit: [],
    yjit: [],
    zjit: [],
    benchmarks: [],
  },
  headline_memory: {
    no_jit: [],
    yjit: [],
    zjit: [],
    benchmarks: [],
  },
  other: {
    no_jit: [],
    yjit: [],
    zjit: [],
    benchmarks: [],
  },
  other_memory: {
    no_jit: [],
    yjit: [],
    zjit: [],
    benchmarks: [],
  },
  micro: {
    no_jit: [],
    yjit: [],
    zjit: [],
    benchmarks: [],
  },
  micro_memory: {
    no_jit: [],
    yjit: [],
    zjit: [],
    benchmarks: [],
  },
}

benchmarks.sort_by(&:first).each do |benchmark, metadata|
  results = benchmark_results.fetch(benchmark)
  memory = memory_results.fetch(benchmark)
  category = metadata.fetch(:category, 'other').to_sym
  memory_category = "#{category}_memory".to_sym

  # Process speed data
  no_jit, yjit, zjit = results[ruby]
  if no_jit
    dashboard[category][:no_jit] << format_float(no_jit / no_jit)
    dashboard[category][:yjit] << (yjit ? format_float(no_jit / yjit) : 0.0)
    dashboard[category][:zjit] << (zjit ? format_float(no_jit / zjit) : 0.0)
    dashboard[category][:benchmarks] << benchmark.to_s
  end

  # Process memory data (if available)
  if memory[ruby]
    no_jit_mem, yjit_mem, zjit_mem = memory[ruby]
    if no_jit_mem
      # Memory is in bytes, convert to MB for dashboard
      dashboard[memory_category][:no_jit] << format_float(no_jit_mem / 1024.0 / 1024.0)
      dashboard[memory_category][:yjit] << (yjit_mem ? format_float(yjit_mem / 1024.0 / 1024.0) : 0.0)
      dashboard[memory_category][:zjit] << (zjit_mem ? format_float(zjit_mem / 1024.0 / 1024.0) : 0.0)
      dashboard[memory_category][:benchmarks] << benchmark.to_s
    end
  end
end

dashboard = dashboard.transform_keys(&:to_s).transform_values do |value|
  value.is_a?(Hash) ? value.transform_keys(&:to_s) : value
end
File.write(File.expand_path('../results/dashboard.yml', __dir__), dashboard.to_yaml)
