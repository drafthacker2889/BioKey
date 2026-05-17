require 'net/http'
require 'uri'
require 'json'

target_url = ENV.fetch('PERF_GATE_URL', 'http://127.0.0.1:4567/health')
requests = ENV.fetch('PERF_GATE_REQUESTS', '30').to_i
p95_budget_ms = ENV.fetch('PERF_GATE_P95_MS', '350').to_f

requests = 10 if requests < 10

uri = URI.parse(target_url)
latencies_ms = []
status_counts = Hash.new(0)

requests.times do
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  response = Net::HTTP.start(uri.host, uri.port, read_timeout: 3, open_timeout: 3) do |http|
    http.request(Net::HTTP::Get.new(uri.request_uri))
  end

  elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000.0
  latencies_ms << elapsed_ms
  status_counts[response.code] += 1

  unless response.code.to_i == 200
    abort("Performance gate failed: non-200 response #{response.code}")
  end
end

sorted = latencies_ms.sort
idx = [(0.95 * sorted.length).ceil - 1, 0].max
p95 = sorted[idx]
avg = latencies_ms.sum / latencies_ms.length
max = sorted[-1]

puts({
  requests: requests,
  target_url: target_url,
  status_counts: status_counts,
  avg_ms: avg.round(2),
  p95_ms: p95.round(2),
  max_ms: max.round(2),
  budget_p95_ms: p95_budget_ms
}.to_json)

if p95 > p95_budget_ms
  abort("Performance gate failed: p95=#{p95.round(2)}ms exceeds budget=#{p95_budget_ms}ms")
end

puts 'Performance gate passed'
